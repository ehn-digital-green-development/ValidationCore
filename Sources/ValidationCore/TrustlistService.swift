//
//  File.swift
//  
//
//  Created by Dominik Mocher on 26.04.21.
//

import Foundation
import SwiftCBOR
import CocoaLumberjackSwift
import Security

public protocol TrustlistService {
    func key(for keyId: Data, keyType: CertType, completionHandler: @escaping (Result<SecKey, ValidationError>)->())
    func key(for keyId: Data, cwt: CWT, keyType: CertType, completionHandler: @escaping (Result<SecKey, ValidationError>)->())
    func updateTrustlistIfNecessary(completionHandler: @escaping (ValidationError?)->())
}

class DefaultTrustlistService : TrustlistService {
    private let trustlistUrl : String
    private let signatureUrl : String
    private let TRUSTLIST_FILENAME = "trustlist"
    private let TRUSTLIST_KEY_ALIAS = "trustlist_key"
    private let LAST_UPDATE_KEY = "last_trustlist_update"
    private let dateService : DateService
    private var cachedTrustlist : TrustList
    private let fileStorage : FileStorage
    private let trustlistAnchor : String
    private let updateInterval = TimeInterval(1.hour)
    private var lastUpdate : Date {
        get {
            if let isoDate = UserDefaults().string(forKey: LAST_UPDATE_KEY),
               let date = ISO8601DateFormatter().date(from: isoDate) {
                return date
            }
            return Date(timeIntervalSince1970: 0)
        }
        set {
            let isoDate = ISO8601DateFormatter().string(from: newValue)
            UserDefaults().set(isoDate, forKey: LAST_UPDATE_KEY)
        }
    }
    
    init(dateService: DateService, trustlistUrl: String, signatureUrl: String, trustAnchor: String) {
        self.trustlistUrl = trustlistUrl
        self.signatureUrl = signatureUrl
        trustlistAnchor = trustAnchor
        self.fileStorage = FileStorage()
        cachedTrustlist = TrustList()
        self.dateService = dateService
        self.loadCachedTrustlist()
        updateTrustlistIfNecessary() { _ in }
    }
    
    public func key(for keyId: Data, keyType: CertType, completionHandler: @escaping (Result<SecKey, ValidationError>)->()){
        key(for: keyId, keyType: keyType, cwt: nil, completionHandler: completionHandler)
    }
    
    public func key(for keyId: Data, cwt: CWT, keyType: CertType, completionHandler: @escaping (Result<SecKey, ValidationError>)->()){
        return key(for: keyId, keyType: keyType, cwt: cwt, completionHandler: completionHandler)
    }
    
    private func key(for keyId: Data, keyType: CertType, cwt: CWT?, completionHandler: @escaping (Result<SecKey, ValidationError>)->()){
        if dateService.isNowBefore(lastUpdate.addingTimeInterval(updateInterval)) {
                    DDLogDebug("Skipping trustlist update...")
                    cachedKey(from: keyId, for: keyType, cwt: cwt, completionHandler)
                    return
                }
                
                updateTrustlistIfNecessary { error in
                    if let error = error {
                        DDLogError("Cannot refresh trust list: \(error)")
                    }
                    self.cachedKey(from: keyId, for: keyType, cwt: cwt, completionHandler)
                }
    }
    
    public func updateTrustlistIfNecessary(completionHandler: @escaping (ValidationError?)->()) {
        updateDetachedSignature() { result in
            switch result {
            case .success(let hash):
                self.lastUpdate = self.dateService.now
                if hash != self.cachedTrustlist.hash {
                    self.updateTrustlist(for: hash, completionHandler)
                    return
                }
                completionHandler(nil)
            case .failure(let error):
                completionHandler(error)
            }
        }
    }
    
    private func updateTrustlist(for hash: Data, _ completionHandler: @escaping (ValidationError?)->()) {
        guard let request = self.defaultRequest(to: self.trustlistUrl) else {
            completionHandler(.TRUST_SERVICE_ERROR)
            return
        }
        
        URLSession.shared.dataTask(with: request) { body, response, error in
            guard self.isResponseValid(response, error), let body = body else {
                DDLogError("Cannot query trustlist service")
                completionHandler(.TRUST_SERVICE_ERROR)
                return
            }
            guard self.refreshTrustlist(from: body, for: hash) else {
                completionHandler(.TRUST_SERVICE_ERROR)
                return
            }
            completionHandler(nil)
        }.resume()
    }
    
    private func updateDetachedSignature(completionHandler: @escaping (Result<Data, ValidationError>)->()) {
        guard let request = defaultRequest(to: signatureUrl) else {
            completionHandler(.failure(.TRUST_SERVICE_ERROR))
            return
        }
        
        URLSession.shared.dataTask(with: request) { body, response, error in
            guard self.isResponseValid(response, error), let body = body else {
                completionHandler(.failure(.TRUST_SERVICE_ERROR))
                return
            }
            guard let cose = Cose(from: body),
                  let trustAnchorKey = self.trustAnchorKey(),
                  cose.hasValidSignature(for: trustAnchorKey) else {
                completionHandler(.failure(.TRUST_LIST_SIGNATURE_INVALID))
                return
            }
            guard let cwt = CWT(from: cose.payload),
                  let trustlistHash = cwt.sub else {
                completionHandler(.failure(.TRUST_SERVICE_ERROR))
                return
            }
            guard cwt.isAlreadyValid(using: self.dateService) else {
                completionHandler(.failure(.TRUST_LIST_NOT_YET_VALID))
                return
            }
            
            guard cwt.isNotExpired(using: self.dateService) else {
                completionHandler(.failure(.TRUST_LIST_EXPIRED))
                return
            }
            
            completionHandler(.success(trustlistHash))
        }.resume()
    }
    
    private func defaultRequest(to url: String) -> URLRequest? {
        guard let url = URL(string: url) else {
            return nil
        }
        var request = URLRequest(url: url)
        request.addValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }
    
    private func isResponseValid(_ response: URLResponse?, _ error: Error?) -> Bool {
        guard error == nil,
              let status = (response as? HTTPURLResponse)?.statusCode,
              200 == status else {
            return false
        }
        return true
    }
    
    private func cachedKey(from keyId: Data, for keyType: CertType, cwt: CWT?, _ completionHandler: @escaping (Result<SecKey, ValidationError>)->()) {
        guard let entry = cachedTrustlist.entry(for: keyId) else {
            completionHandler(.failure(.KEY_NOT_IN_TRUST_LIST))
            return
        }
        guard entry.isValid(for: dateService) else {
            completionHandler(.failure(.PUBLIC_KEY_EXPIRED))
            return
        }
        guard entry.isSuitable(for: keyType) else {
            completionHandler(.failure(.UNSUITABLE_PUBLIC_KEY_TYPE))
            return
        }
        
        if let cwtIssuedAt = cwt?.issuedAt,
           let cwtExpiresAt = cwt?.expiresAt,
           let certNotBefore = entry.notBefore,
           let certNotAfter = entry.notAfter {
            guard certNotBefore.isBefore(cwtIssuedAt) && certNotAfter.isAfter(cwtIssuedAt) && certNotAfter.isAfter(cwtExpiresAt) else {
                completionHandler(.failure(.CWT_EXPIRED))
                return
            }
        }
        
        guard let secKey = entry.publicKey else {
            completionHandler(.failure(.KEY_CREATION_ERROR))
            return
        }
        completionHandler(.success(secKey))
    }
    
    private func refreshTrustlist(from data: Data, for hash: Data) -> Bool {
        guard let cbor = try? CBORDecoder(input: data.bytes).decodeItem(),
              var trustlist = try? CodableCBORDecoder().decode(TrustList.self, from: cbor.asData()) else {
            return false
        }
        trustlist.hash = hash
        self.cachedTrustlist = trustlist
        storeTrustlist()
        return true
    }
    
    private func storeTrustlist(){
        guard let trustlistData = try? JSONEncoder().encode(self.cachedTrustlist) else {
            DDLogError("Cannot encode trustlist for storing")
            return
        }
        CryptoService.createKeyAndEncrypt(data: trustlistData, with: self.TRUSTLIST_KEY_ALIAS, completionHandler: { result in
            switch result {
            case .success(let data):
                if !self.fileStorage.writeProtectedFileToDisk(fileData: data, with: self.TRUSTLIST_FILENAME) {
                    DDLogError("Cannot write trustlist to disk")
                }
            case .failure(let error): DDLogError(error)
            }
        })
    }
    
    private func loadCachedTrustlist(){
        if let trustlistData = fileStorage.loadProtectedFileFromDisk(with: TRUSTLIST_FILENAME) {
            CryptoService.decrypt(ciphertext: trustlistData, with: TRUSTLIST_KEY_ALIAS) { result in
                switch result {
                case .success(let plaintext):
                    if let trustlist = try? JSONDecoder().decode(TrustList.self, from: plaintext) {
                        self.cachedTrustlist = trustlist
                    }
                case .failure(let error): DDLogError("Cannot load cached trust list: \(error)")
                }
            }
        }
    }
    
    private func trustAnchorKey() -> SecKey? {
        guard let certData = Data(base64Encoded: trustlistAnchor),
              let certificate = SecCertificateCreateWithData(nil, certData as CFData),
              let secKey = SecCertificateCopyKey(certificate) else {
            return nil
        }
        return secKey
    }
}
