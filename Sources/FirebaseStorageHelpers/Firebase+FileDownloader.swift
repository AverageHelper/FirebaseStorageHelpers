//
//  Firebase+FileDownloader.swift
//  CloudStorage
//
//  Created by James Robinson on 2/6/20.
//

#if canImport(Combine) && canImport(CryptoKit) && canImport(Firebase)
import Foundation
import Combine
import CryptoKit
import FirebaseStorage
import CloudStorage

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension DownloadError {
    
    public init(code: StorageErrorCode) {
        switch code {
        case .bucketNotFound:       self = .development("Bucket not configured")
        case .cancelled:            self = .cancelled
        case .downloadSizeExceeded: self = .development("Insufficient Memory")
        case .invalidArgument:      self = .development("Invalid argument")
        case .objectNotFound:       self = .itemNotFound
        case .projectNotFound:      self = .development("Project not configured")
        case .quotaExceeded:        self = .serviceUnavailable
        case .retryLimitExceeded:   self = .networkUnavailable
        case .unauthenticated:      self = .notAuthenticated
        case .unauthorized:         self = .unauthorized
        default:                    self = .unknown
        }
    }
    
}

// MARK: Publisher

/// A `Publisher` which downloads data from Firebase, publishing the value when finished.
///
/// To begin the download, subscribe to this publisher.
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class FirebaseFileDownloader<Downloadable>: FileDownloader where Downloadable: FirebaseDownloadable {
    
    public static func downloadFile(_ file: Downloadable,
                                    to outputDirectory: URL,
                                    decryptingUsing decryptionKey: SymmetricKey?) throws -> FirebaseFileDownloader<Downloadable> {
        // Online Path: /{userID}/records/{recordID}/images/{itemID}.imageData
        guard let ref = file.firebaseRef()
            else { throw DownloadError.notAuthenticated }
        
        // Local path
        let cachedItemURL: URL
        
        if outputDirectory.hasDirectoryPath { // If it's a directory, add file name
            cachedItemURL = outputDirectory
                .appendingPathComponent(file.id.uuidString, isDirectory: false)
                .appendingPathExtension(file.fileExtension ?? "")
        } else { // If it's a file, use that.
            cachedItemURL = outputDirectory
        }
        
        return FirebaseFileDownloader(ref: ref,
                                      outputFileURL: cachedItemURL,
                                      decryptionKey: decryptionKey)
    }
    
    public static func deleteFile(_ file: Downloadable) throws -> FirebaseFileDeleter<Downloadable> {
        guard let ref = file.firebaseRef()
            else { throw DownloadError.notAuthenticated }
        
        return FirebaseFileDeleter(ref: ref)
    }
    
    public let ref: Downloadable.ReferenceType
    private let decryptionKey: SymmetricKey?
    private let outputFileURL: URL
    
    public init(ref: Downloadable.ReferenceType,
                outputFileURL: URL,
                decryptionKey: SymmetricKey?) {
        self.ref = ref
        self.outputFileURL = outputFileURL
        self.decryptionKey = decryptionKey
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, DownloadError == S.Failure, DownloadProgress == S.Input {
        let subscription =
            FirebaseDownloadSubscription(
                subscriber: subscriber,
                ref: ref,
                outputFileURL: outputFileURL,
                decryptionKey: decryptionKey
            )
        subscriber.receive(subscription: subscription)
    }
    
}

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class FirebaseFileDeleter<Deletable>: FileDeleter where Deletable: FirebaseDownloadable {
    
    public let ref: Deletable.ReferenceType
    
    public init(ref: Deletable.ReferenceType) {
        self.ref = ref
    }
    
    public func receive<S>(subscriber: S) where S: Subscriber, DownloadError == S.Failure, Never == S.Input {
        let subscription = FirebaseDeletionSubscription(subscriber: subscriber, ref: ref)
        subscriber.receive(subscription: subscription)
    }
    
}

// MARK: Download Subscription

/// A `Subscription` which handles the observation of a running `StorageDownloadTask`.
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class FirebaseDownloadSubscription<SubscriberType, ReferenceType>: Subscription
    where SubscriberType: Subscriber,
    DownloadError == SubscriberType.Failure,
    DownloadProgress == SubscriberType.Input,
    ReferenceType: StorageReferenceType {
    
    private var subscriber: SubscriberType?
    private var fileRef: ReferenceType
    private var downloadTask: ReferenceType.DownloadTaskType?
    private let outputFileURL: URL
    private let decryptionKey: SymmetricKey?
    
    public private(set) var latestProgress: DownloadProgress
    
    fileprivate init(subscriber: SubscriberType,
                     ref: ReferenceType,
                     outputFileURL: URL,
                     decryptionKey: SymmetricKey?) {
        self.subscriber = subscriber
        self.fileRef = ref
        self.downloadTask = nil
        self.outputFileURL = outputFileURL
        self.decryptionKey = decryptionKey
        self.latestProgress = DownloadProgress(completedBytes: 0, totalBytes: nil)
    }
    
    public func request(_ demand: Subscribers.Demand) {
        guard downloadTask == nil else { return }
        let temporaryFileURL: URL
        do {
            temporaryFileURL = try FileManager.default
                .url(for: .itemReplacementDirectory,
                     in: .userDomainMask,
                     appropriateFor: outputFileURL,
                     create: true)
                .appendingPathComponent(outputFileURL.lastPathComponent, isDirectory: false)
        } catch let error as CocoaError {
            return handleFailure(error: .disk(error), partiallyDownloadedFileURL: nil)
        } catch {
            print("[FirebaseDownloadSubscription] Unknown error while creating temporary directory: \(error)")
            return handleFailure(error: .unknown, partiallyDownloadedFileURL: nil)
        }
        downloadTask = fileRef.write(toFile: temporaryFileURL)
        
        guard let task = self.downloadTask else { return }
        
        // Observe download
        task.observe(.failure) { [weak self] (snap) in
            guard let strongSelf = self else { return }
            guard let error = snap.error as NSError? else {
                return strongSelf.handleFailure(code: .unknown, partiallyDownloadedFileURL: temporaryFileURL)
            }
            let code = StorageErrorCode(rawValue: error.code)!
            strongSelf.handleFailure(code: code, partiallyDownloadedFileURL: temporaryFileURL)
        }
        task.observe(.success) { [weak self] (snap) in
            if let error = snap.error as NSError? {
                let code = StorageErrorCode(rawValue: error.code)!
                self?.handleFailure(code: code, partiallyDownloadedFileURL: temporaryFileURL)
            } else {
                if let strongSelf = self {
                    strongSelf.latestProgress.completedBytes =
                        strongSelf.latestProgress.totalBytes ?? strongSelf.latestProgress.completedBytes
                    _ = strongSelf.subscriber?.receive(strongSelf.latestProgress)
                }
                self?.handleSuccess(downloadedFileURL: temporaryFileURL)
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
            print("[FirebaseDownloadSubscription] Downloading file \(snap.reference.name): \(progress.fractionCompleted, style: .percent) percent completed.")
            strongSelf.latestProgress.totalBytes = Int(progress.totalUnitCount)
            strongSelf.latestProgress.completedBytes = Int(progress.completedUnitCount)
            _ = strongSelf.subscriber?.receive(strongSelf.latestProgress)
        }
    }
    
    public func cancel() {
        downloadTask?.cancel()
        // In case we don't get the cancellation event...
        handleFailure(error: .cancelled, partiallyDownloadedFileURL: nil)
        downloadTask = nil
    }
    
    private func handleFailure(code: StorageErrorCode, partiallyDownloadedFileURL: URL?) {
        let error = DownloadError(code: code)
        #if DEBUG
        print("[FirebaseDownloadSubscription] Handling Firebase error code '\(code.rawValue)' as error: \(error)")
        #endif
        handleFailure(error: error, partiallyDownloadedFileURL: partiallyDownloadedFileURL)
    }
    
    private func handleFailure(error: DownloadError, partiallyDownloadedFileURL: URL?) {
        #if DEBUG
        print("[FirebaseDownloadSubscription] Download failed: \(error)")
        #endif
        
        subscriber?.receive(completion: .failure(error))
        subscriber = nil
        guard let junkFile = partiallyDownloadedFileURL else { return }
        do {
            try FileManager.default
                .removeItem(at: junkFile.deletingLastPathComponent())
        } catch {
            print("[FirebaseDownloadSubscription] Failed to remove partially downloaded file in folder \(junkFile.deletingLastPathComponent().path)")
        }
    }
    
    /// The queue for decrypting downloaded data.
    private lazy var workQueue: DispatchQueue = {
        let label = "FirebaseDownloadSubscription.workQueue(\(UUID().uuidString))"
        return DispatchQueue(label: label, qos: .utility)
    }()
    
    private func handleSuccess(downloadedFileURL: URL) {
        #if DEBUG
        print("[FirebaseDownloadSubscription] Download complete.")
        #endif
        
        if let total = latestProgress.totalBytes {
            latestProgress.completedBytes = total
        }
        
        workQueue.async {
            do {
                if let key = self.decryptionKey { // Decrypt!
                    let rawData = try Data(contentsOf: downloadedFileURL)
                    let box = try ChaChaPoly.SealedBox(combined: rawData)
                    let decryptedData = try ChaChaPoly.open(box, using: key)
                    
                    try FileManager.default // Delete the temporary directory
                        .removeItem(at: downloadedFileURL.deletingLastPathComponent())
                    try FileManager.default // Prepare our destination directory
                        .createDirectory(at: self.outputFileURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
                    try? FileManager.default // Remove existing output, if any
                        .removeItem(at: self.outputFileURL)
                    try decryptedData
                        .write(to: self.outputFileURL,
                               // This does nothing on macOS
                               options: .completeFileProtection)
                    
                } else { // Just move the downloaded file
                    try? FileManager.default // Remove existing cache, if any
                        .removeItem(at: self.outputFileURL)
                    try FileManager.default // Move the downloaded file
                        .moveItem(at: downloadedFileURL, to: self.outputFileURL)
                    try FileManager.default // Delete the temporary directory
                        .removeItem(at: downloadedFileURL.deletingLastPathComponent())
                }
                self.subscriber?.receive(completion: .finished)
                self.subscriber = nil
                
            } catch let error as CocoaError {
                print("[FirebaseDownloadSubscription] Failed to copy from '\(downloadedFileURL.path)' to output file '\(self.outputFileURL.path)': \(error)")
                self.handleFailure(error: .disk(error), partiallyDownloadedFileURL: nil)
            } catch let error as CryptoKitError {
                print("[FirebaseDownloadSubscription] Failed to decrypt downloaded payload: \(error)")
                self.handleFailure(error: .decryption(error), partiallyDownloadedFileURL: nil)
            } catch {
                print("[FirebaseDownloadSubscription] Unknown error while finishing download operation: \(error)")
                self.handleFailure(error: .unknown, partiallyDownloadedFileURL: nil)
            }
        }
    }
    
}

@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension Progress {
    
    /// Updates the progress object using properties of the given `snapshot`'s progress.
    internal func update<S>(with snapshot: S) where S: StorageTaskSnapshotType {
        self.completedUnitCount = snapshot.progress?.completedUnitCount ?? completedUnitCount
        self.totalUnitCount = snapshot.progress?.totalUnitCount ?? totalUnitCount
        self.estimatedTimeRemaining = snapshot.progress?.estimatedTimeRemaining
        self.fileCompletedCount = snapshot.progress?.fileCompletedCount
        self.fileTotalCount = snapshot.progress?.fileTotalCount
        self.fileURL = snapshot.progress?.fileURL
        self.throughput = snapshot.progress?.throughput
        
        if snapshot.progress?.isFinished == true {
            self.localizedDescription = "Download Complete"
        }
    }
    
}

// MARK: Deletion Subscription

/// A `Subscription` which handles the observation of a reference's deletion.
@available(OSX 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
public final class FirebaseDeletionSubscription<SubscriberType, ReferenceType>: Subscription
    where SubscriberType: Subscriber,
    DownloadError == SubscriberType.Failure,
    Never == SubscriberType.Input,
    ReferenceType: StorageReferenceType {
    
    private var subscriber: SubscriberType?
    private var fileRef: ReferenceType
    
    fileprivate init(subscriber: SubscriberType,
                     ref: ReferenceType) {
        self.subscriber = subscriber
        self.fileRef = ref
    }
    
    public func request(_ demand: Subscribers.Demand) {
        fileRef.delete { [weak self] (deletionError) in
            guard let strongSelf = self else { return }
            
            if let error = deletionError as NSError? {
                let code = StorageErrorCode(rawValue: error.code)!
                return strongSelf.handleFailure(code: code)
                
            } else if deletionError != nil {
                return strongSelf.handleFailure(code: .unknown)
            }
            
            strongSelf.handleSuccess()
        }
    }
    
    public func cancel() {
        // We can't really handle these...
    }
    
    private func handleFailure(code: StorageErrorCode) {
        let error = DownloadError(code: code)
        #if DEBUG
        print("[FirebaseDeletionSubscription] Handling Firebase error code '\(code.rawValue)' as error: \(error)")
        #endif
        handleFailure(error: error)
    }
    
    private func handleFailure(error: DownloadError) {
        #if DEBUG
        print("[FirebaseDeletionSubscription] Deletion failed: \(error)")
        #endif
        
        subscriber?.receive(completion: .failure(error))
        subscriber = nil
    }
    
    private func handleSuccess() {
        #if DEBUG
        print("[FirebaseDeletionSubscription] Deletion complete.")
        #endif
        
        self.subscriber?.receive(completion: .finished)
        self.subscriber = nil
    }
    
}


// MARK: - Firebase Protocols



// MARK: Downloadable

/// A type that conforms to this protocol may be used by `FirebaseFileDownloader`s to retrieve
/// data from Firebase Storage.
public protocol FirebaseDownloadable: Downloadable {
    
    associatedtype ReferenceType: StorageReferenceType
    
    /// Returns a storage reference for the file if the user is signed in. `nil` otherwise.
    ///
    /// The path returned is in the form:
    ///
    ///     /{userID}/records/{imageRecordID}/images/{imageID}.imageData
    ///
    /// - Returns: A Firebase Storage reference, or `nil` if the user is not signed in.
    func firebaseRef() -> ReferenceType?
    
    static var firebaseUserID: String? { get }
    
}

// MARK: Storage Reference

/// A type that conforms to this protocol may be used to reference downloadable data in Firebase Storage.
public protocol StorageReferenceType {
    
    /// The short name of the object associated with this reference, in gs://bucket/path/to/object.txt,
    /// the name of the object would be: 'object.txt'
    var name: String { get }
    
    associatedtype DownloadTaskType: StorageDownloadTaskType
    associatedtype UploadTaskType: StorageUploadTaskType
    
    /// Asynchronously downloads the object at the current path to a specified system `fileURL`.
    ///
    /// - Parameter fileURL: A file system `URL` representing the path the object should be downloaded to.
    /// - Returns: A `StorageDownloadTask` that can be used to monitor or manage the download.
    func write(toFile fileURL: URL) -> DownloadTaskType
    
    /// Asynchronously uploads data to the currently specified `StorageReference`, without additional metadata.
    /// This is not recommended for large files, and one should instead upload a file from disk.
    func putData(_ uploadData: Data) -> UploadTaskType
    
    /// Deletes the obejct at the current path.
    /// - Parameter completion: A completion block which returns `nil` on success, or an error on failure.
    func delete(completion: ((Error?) -> Void)?)
    
    /// Asynchronously retrieves a long lived download URL with a revokable token. This can be used to share
    /// the file with others, but can be revoked by a developer in the Firebase Console if desired.
    func downloadURL(completion: @escaping (URL?, Error?) -> Void)
}

extension StorageReference: StorageReferenceType {}

// MARK: Storage Task Snapshot

/// A type that conforms to this protocol may be used to proxy Firebase task snapshots.
public protocol StorageTaskSnapshotType {
    associatedtype ReferenceType: StorageReferenceType
    
    var progress: Progress? { get }
    var error: Error? { get }
    var reference: ReferenceType { get }
}

extension StorageTaskSnapshot: StorageTaskSnapshotType {}

// MARK: Storage Task

public protocol StorageTaskType: Cancellable {
    associatedtype Snapshot: StorageTaskSnapshotType
    
    /// Pauses a task currently in progress.
    func pause()
    
    /// Resumes a task that is paused.
    func resume()
    
    /// Observes changes in the upload status: Resume, Pause, Progress, Success, and Failure.
    /// - Parameters:
    ///   - status: The `StorageTaskStatus` change to observe.
    ///   - handler: A callback that fires every time the status event occurs, returns a
    ///     `StorageTaskSnapshot` containing the state of the task.
    /// - Returns: A task handle that can be used to remove the observer at a later date.
    @discardableResult
    func observe(_ status: StorageTaskStatus, handler: @escaping (Snapshot) -> Void) -> String
}

/// A type that conforms to this protocol may be used as a proxy to observe and manage the status of a
/// Firebase Storage download.
public protocol StorageDownloadTaskType: StorageTaskType {}

extension StorageDownloadTask: StorageDownloadTaskType {}
#endif
