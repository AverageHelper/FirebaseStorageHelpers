//
//  Mocks.swift
//  FirebaseStorageHelpersTests
//
//  Created by James Robinson on 4/6/20.
//

#if canImport(Combine) && canImport(CryptoKit) && canImport(FirebaseStorage)
import Foundation
import CloudStorage
import FirebaseStorage
import FirebaseStorageHelpers

/// A shared fake Firebase instance.
enum FirebaseMock {
    /// Represents the contents of Firebase Storage after mocking file upload and download tasks.
    static var uploadedData = [String: Data]()
}

struct Snapshot: StorageTaskSnapshotType {
    let reference: Reference
    var progress: Progress? = nil
    var error: Error? = nil
}

final class Task: StorageUploadTaskType, StorageDownloadTaskType {
    
    enum TaskType {
        case upload(payload: Data)
        case download(output: URL)
    }
    
    var observations = [String: (StorageTaskStatus, (Snapshot) -> Void)]()
    let type: TaskType
    
    init(reference: Snapshot.ReferenceType, type: TaskType) {
        self.snapshot = Snapshot(reference: reference)
        self.type = type
    }
    
    /// The current task snapshot.
    private var snapshot: Snapshot
    
    /// Calls and then invalidates observation handlers for the given task `status`.
    private func callHandlers(for status: StorageTaskStatus) {
        for (key, observation) in observations where observation.0 == status {
            let callback = observations.removeValue(forKey: key)
            callback?.1(snapshot)
        }
    }
    
    /// Simulates task failure after `seconds` of work.
    func simulateFailure(delay seconds: TimeInterval = 1, error: Error) {
        guard self.snapshot.progress == nil else { return } // Can't have started yet
        
        self.snapshot.progress = Progress(totalUnitCount: 4)
        
        // If delay > 0, also simulate occasional progress
        if seconds > 0 {
            simulateProgress(count: 3, throughoutInterval: seconds)
        }
        
        snapshot.error = error
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            if self.isCancelled {
                self.snapshot.error = NSError(domain: StorageErrorDomain,
                                              code: StorageErrorCode.cancelled.rawValue,
                                              userInfo: nil)
            }
            
            guard !self.isCancelled else { return }
            self.callHandlers(for: .failure)
            self.progressQueue = nil
            self.observations.removeAll()
        }
    }
    
    /// Simulates task completion after `seconds` of work.
    func simulateTask(completionDelay seconds: TimeInterval = 0) {
        guard self.snapshot.progress == nil else { return } // Can't have started yet
        
        self.snapshot.progress = Progress(totalUnitCount: 4)
        
        // If completionDelay > 0, also simulate occasional progress
        if seconds > 0 {
            simulateProgress(count: 3, throughoutInterval: seconds)
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            guard !self.isCancelled && !self.isPaused else {
                if self.isCancelled {
                    let error = NSError(domain: StorageErrorDomain,
                                        code: StorageErrorCode.cancelled.rawValue,
                                        userInfo: nil)
                    self.snapshot.error = error
                    self.callHandlers(for: .failure)
                    self.progressQueue = nil
                    self.observations.removeAll()
                }
                return
            }
            
            let path = self.snapshot.reference.path
            switch self.type {
            // Run the mock up/download
                
            case .upload(let data):
                // Put data in mock Firebase
                FirebaseMock.uploadedData[path] = data
                self.finish(with: .success)
                
            case .download(let outputURL):
                // Grab data from mock Firebase
                guard let data = FirebaseMock.uploadedData[path] else {
                    return self.finish(with: .failure, errorCode: .objectNotFound)
                }
                do {
                    try data.write(to: outputURL)
                    return self.finish(with: .success)
                } catch {
                    return self.finish(with: .failure, errorCode: .unknown)
                }
            }
        }
    }
    
    private func finish(with status: StorageTaskStatus, errorCode: StorageErrorCode? = nil) {
        if let code = errorCode {
            let error = NSError(domain: StorageErrorDomain, code: code.rawValue, userInfo: nil)
            self.snapshot.error = error
        }
        self.snapshot.progress?.completedUnitCount = 4
        self.callHandlers(for: status)
        self.progressQueue = nil
        self.observations.removeAll()
    }
    
    private var progressQueue: OperationQueue?
    
    /// Simualtes occasional task progress.
    private func simulateProgress(count: Int, throughoutInterval totalInterval: TimeInterval) {
        progressQueue = OperationQueue()
        let work = { () -> Void in
            let totalTime = totalInterval * 0.98
            let waitTime = totalTime / Double(count)
            Thread.sleep(forTimeInterval: waitTime)
            
            guard !self.isCancelled && !self.isPaused else { return }
            self.snapshot.progress?.completedUnitCount += 1
            self.callHandlers(for: .progress)
        }
        progressQueue?.maxConcurrentOperationCount = 1
        progressQueue?.qualityOfService = .utility
        progressQueue?.addOperations([
            BlockOperation(block: work),
            BlockOperation(block: work),
            BlockOperation(block: work)
        ], waitUntilFinished: false)
    }
    
    func observe(_ status: StorageTaskStatus, handler: @escaping (Snapshot) -> Void) -> String {
        let observationID = UUID().uuidString
        observations[observationID] = (status, handler)
        return observationID
    }
    
    var isCancelled = false {
        didSet {
            guard isCancelled else { return }
            snapshot.progress?.cancel()
        }
    }
    
    var isPaused = false {
        didSet {
            if isPaused && !oldValue {
                callHandlers(for: .pause)
            } else if !isPaused && oldValue {
                callHandlers(for: .resume)
            }
        }
    }
    
    func cancel() {
        isCancelled = true
    }
    
    func pause() {
        guard !isCancelled else { return }
        isPaused = true
    }
    
    func resume() {
        guard !isCancelled else { return }
        isPaused = false
    }
    
}

struct Reference: StorageReferenceType, Equatable {
    
    static func == (lhs: Reference, rhs: Reference) -> Bool {
        return lhs.path == rhs.path
    }
    
    var path: String
    
    init(path: String,
         downloadFailure: StorageErrorCode? = nil,
         uploadFailure: StorageErrorCode? = nil,
         deletionFailure: StorageErrorCode? = nil) {
        self.path = path
        self.downloadFailure = downloadFailure
        self.uploadFailure = uploadFailure
        self.deletionFailure = deletionFailure
    }
    
    var name: String { String(path.split(separator: "/").last!) }
    
    var completionDelay: TimeInterval = 0
    
    /// Set this value to simulate file download failure.
    var downloadFailure: StorageErrorCode?
    @ObjectStorage private var downloadURL: URL?
    
    func write(toFile fileURL: URL) -> Task {
        print("[Reference] write(toFile:'\(fileURL.path)'")
        
        let task = Task(reference: self, type: .download(output: fileURL))
        if let code = downloadFailure {
            let error = NSError(domain: StorageErrorDomain, code: code.rawValue, userInfo: nil)
            task.simulateFailure(delay: completionDelay, error: error)
        } else {
            self.downloadURL = fileURL
            task.simulateTask(completionDelay: completionDelay)
        }
        
        return task
    }
    
    /// Set this value to simulate file upload failure.
    var uploadFailure: StorageErrorCode? = nil
    
    func putData(_ uploadData: Data) -> Task {
        print("[Reference] putData(\(uploadData))")
        
        let task = Task(reference: self, type: .upload(payload: uploadData))
        if let code = uploadFailure {
            let error = NSError(domain: StorageErrorDomain, code: code.rawValue, userInfo: nil)
            task.simulateFailure(delay: completionDelay, error: error)
        } else {
            downloadURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(name, isDirectory: false)
            task.simulateTask(completionDelay: completionDelay)
        }
        
        return task
    }
    
    /// Set this value to simulate file deletion failure.
    var deletionFailure: StorageErrorCode?
    
    func delete(completion: ((Error?) -> Void)?) {
        print("[Reference] delete(completion: \(String(describing: completion))")
        
        DispatchQueue.main.async {
            var error: Error?
            if let code = self.deletionFailure {
                error = NSError(domain: StorageErrorDomain, code: code.rawValue, userInfo: nil)
            } else {
                let extantData = FirebaseMock.uploadedData.removeValue(forKey: self.path)
                if extantData == nil {
                    error = NSError(domain: StorageErrorDomain, code: StorageErrorCode.objectNotFound.rawValue, userInfo: nil)
                }
            }
            
            completion?(error)
        }
    }
    
    func downloadURL(completion: @escaping (URL?, Error?) -> Void) {
        DispatchQueue.main.async {
            if let code = self.uploadFailure ?? self.downloadFailure {
                let error = NSError(domain: StorageErrorDomain, code: code.rawValue, userInfo: nil)
                completion(nil, error)
                
            } else if let url = self.downloadURL { // Successful download
                completion(url, nil)
                
            } else { // Noop!
                let error = NSError(domain: StorageErrorDomain, code: StorageErrorCode.unknown.rawValue, userInfo: nil)
                completion(nil, error)
            }
        }
    }
    
}

struct UploadableThing: FirebaseUploadable, Equatable {
    var payload: Data? = Data(repeating: 5, count: 64)
    var metadata: DownloadableThing
}

final class DownloadableThing: FirebaseDownloadable, Equatable {
    
    static var firebaseUserID: String? = nil
    func firebaseRef() -> Reference? {
        guard let userID = UploadableThing.firebaseUserID else { return nil }
        let recordID = self.recordIdentifier.uuidString
        let itemID = self.id.uuidString
        let ext = fileExtension ?? "testFile"
        
        return Reference(path: "/\(userID)/records/\(recordID)/images/\(itemID).\(ext)")
    }
    
    var recordIdentifier = UUID()
    var id = UUID()
    var fileExtension: String? = "testfile"
    lazy var storage: UploadableThing? = UploadableThing(metadata: self)
    
    static func == (lhs: DownloadableThing, rhs: DownloadableThing) -> Bool {
        return lhs.storage == rhs.storage &&
            lhs.fileExtension == rhs.fileExtension &&
            lhs.id == rhs.id &&
            lhs.recordIdentifier == rhs.recordIdentifier
    }
    
}
#endif
