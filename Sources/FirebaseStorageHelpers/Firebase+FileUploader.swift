//
//  Firebase+FileUploader.swift
//  CloudStorage
//
//  Created by James Robinson on 2/7/20.
//

#if canImport(Combine) && canImport(CryptoKit) && canImport(Firebase)
import Foundation
import Combine
import CryptoKit
import FirebaseStorage
import CloudStorage

extension UploadError {
    
    public init(code: StorageErrorCode) {
        switch code {
        case .bucketNotFound:       self = .development("Bucket not configured")
        case .cancelled:            self = .cancelled
        case .invalidArgument:      self = .development("Invalid argument")
        case .nonMatchingChecksum:  self = .serviceUnavailable
        case .projectNotFound:      self = .development("Project not configured")
        case .quotaExceeded:        self = .serviceUnavailable
        case .retryLimitExceeded:   self = .networkUnavailable
        case .unauthenticated:      self = .notAuthenticated
        case .unauthorized:         self = .unauthorized
        default:                    self = .unknown
        }
    }
    
}

/// An object which kicks off the uploading of a `Uploadable` data.
public final class FirebaseFileUploader<Uploadable>: FileUploader where Uploadable: FirebaseUploadable {
    
    /// - Note: The encryption is done using CryptoKit's `ChaChaPoly.seal` method.
    public static func uploadFile(_ file: Uploadable,
                                  encryptingWithKey encryptionKey: SymmetricKey?) throws -> FirebaseFileUploader<Uploadable> {
        // Online Path
        guard let ref = file.firebaseRef()
            else { throw UploadError.notAuthenticated }
        
        guard let rawData = file.payload
            else { throw UploadError.noData }
        
        // Encrypt the payload, if we're asked to
        var payload: Data
        if let key = encryptionKey {
            payload = try ChaChaPoly.seal(rawData, using: key).combined
        } else {
            payload = rawData
        }
        
        return FirebaseFileUploader(ref: ref,
                                    file: file,
                                    payload: payload)
    }
    
    public let ref: Uploadable.ReferenceType
    private let payload: Data
    private let file: Uploadable
    
    fileprivate init(ref: Uploadable.ReferenceType, file: Uploadable, payload: Data) {
        self.ref = ref
        self.file = file
        self.payload = payload
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, Failure == S.Failure, Output == S.Input {
        let subscription =
            FirebaseUploadSubscription(
                subscriber: subscriber,
                ref: ref,
                data: payload
            )
        subscriber.receive(subscription: subscription)
    }
    
}

public final class FirebaseUploadSubscription<SubscriberType, ReferenceType>: Subscription
    where SubscriberType: Subscriber,
    UploadError == SubscriberType.Failure,
    UploadProgress == SubscriberType.Input,
    ReferenceType: StorageReferenceType {
    
    private var subscriber: SubscriberType?
    private var uploadTask: ReferenceType.UploadTaskType?
    private let fileRef: ReferenceType
    private let dataToUpload: Data
    /// The most recent upload progress event.
    public private(set) var latestProgress: UploadProgress
    
    fileprivate init(subscriber: SubscriberType,
                     ref: ReferenceType,
                     data: Data) {
        self.subscriber = subscriber
        self.fileRef = ref
        self.uploadTask = nil
        self.dataToUpload = data
        self.latestProgress = UploadProgress(completedBytes: 0, totalBytes: data.count)
    }
    
    public func request(_ demand: Subscribers.Demand) {
        guard uploadTask == nil else { return }
        uploadTask = fileRef.putData(dataToUpload)
        
        guard let task = self.uploadTask else { return }
        
        // Observe upload
        task.observe(.failure) { [weak self] (snap) in
            guard let strongSelf = self else { return }
            guard let error = snap.error as NSError? else {
                return strongSelf.handleFailure(code: .unknown)
            }
            let code = StorageErrorCode(rawValue: error.code)!
            strongSelf.handleFailure(code: code)
        }
        task.observe(.success) { [weak self] (snap) in
            if let error = snap.error as NSError? {
                let code = StorageErrorCode(rawValue: error.code)!
                self?.handleFailure(code: code)
            } else {
                if let strongSelf = self {
                    strongSelf.latestProgress.completedBytes = strongSelf.latestProgress.totalBytes
                    _ = strongSelf.subscriber?.receive(strongSelf.latestProgress)
                }
                self?.handleSuccess()
            }
        }
        task.observe(.pause) { _ in
            // Stop, Hammertime!
        }
        task.observe(.resume) { _ in
            // Do it again!
        }
        task.observe(.progress) { [weak self] (snap) in
            guard let strongSelf = self,
                let progress = snap.progress
                else { return }
            print("[FirebaseUploadSubscription] Uploading file \(snap.reference.name): \(progress.fractionCompleted, style: .percent) percent completed.")
            strongSelf.latestProgress.totalBytes = Int(progress.totalUnitCount)
            strongSelf.latestProgress.completedBytes = Int(progress.completedUnitCount)
            _ = strongSelf.subscriber?.receive(strongSelf.latestProgress)
        }
    }
    
    public func cancel() {
        handleFailure(error: .cancelled)
        uploadTask?.cancel()
        uploadTask = nil
    }
    
    public func pause() {
        uploadTask?.pause()
    }
    
    public func resume() {
        uploadTask?.resume()
    }
    
    private func handleFailure(code: StorageErrorCode) {
        let error = UploadError(code: code)
        #if DEBUG
        print("[FirebaseUploadSubscription] Handling Firebase error code '\(code.rawValue)' as error: \(error)")
        #endif
        handleFailure(error: error)
    }
    
    private func handleFailure(error: UploadError) {
        subscriber?.receive(completion: .failure(error))
        subscriber = nil
    }
    
    private func handleSuccess() {
        #if DEBUG
        print("[FirebaseUploadSubscription] Upload complete.")
        #endif

        latestProgress.completedBytes = latestProgress.totalBytes
        _ = subscriber?.receive(latestProgress)
        subscriber?.receive(completion: .finished)
        subscriber = nil
    }
    
}

/// A type that conforms to this protocol may be used by `FirebaseFileUploader`s to send
/// data to Firebase Storage.
public protocol FirebaseUploadable: Uploadable where Metadata: FirebaseDownloadable {}

extension FirebaseUploadable {
    
    public typealias ReferenceType = Metadata.ReferenceType
    
    /// Returns a storage reference for the file if the user is signed in. `nil` otherwise.
    ///
    /// The path returned is in the form:
    ///
    ///     /{userID}/records/{imageRecordID}/images/{imageID}.imageData
    ///
    /// - Returns: A Firebase Storage reference, or `nil` if the user is not signed in.
    func firebaseRef() -> Metadata.ReferenceType? { metadata.firebaseRef() }
    
    static var firebaseUserID: String? { Metadata.firebaseUserID }
}

/// A type that conforms to this protocol may be used as a proxy to observe and manage the status of a
/// Firebase Storage download.
public protocol StorageUploadTaskType: StorageTaskType {}

extension StorageUploadTask: StorageUploadTaskType {}
#endif
