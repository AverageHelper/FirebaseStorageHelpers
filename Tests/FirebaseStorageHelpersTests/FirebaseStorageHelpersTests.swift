import XCTest
import Combine
import CryptoKit
import CloudKit
import CloudStorage
import FirebaseStorageHelpers

@available(OSX 10.15, iOS 13.0, tvOS 13.0, *)
final class FirebaseStorageHelpersTests: XCTestCase {
    
    static var allTests: [(String, (FirebaseStorageHelpersTests) -> () throws -> ())] = [
        ("testStorageRef", testStorageRef),
        ("testUploadProgressFraction", testUploadProgressFraction),
        ("testUploadNotAuthenticated", testUploadNotAuthenticated),
        ("testFirebaseUploadSuccess", testFirebaseUploadSuccess),
        ("testFirebaseEncryptedUpload", testFirebaseEncryptedUpload),
        ("testFirebaseDownloadSuccess", testFirebaseDownloadSuccess),
        ("testFirebaseFileDeleteNonexistent", testFirebaseFileDeleteNonexistent),
    ]
    
    override func setUp() {
        FirebaseMock.uploadedData.removeAll() // Clear mock Storage
        CloudKitMock.defaultContainer.wipe()
        DownloadableThing.firebaseUserID = nil // Sign out of mock
        CloudKitMock.currentUserID = nil
    }
    
    override static func tearDown() {
        // After all tests are done...
        FirebaseMock.uploadedData.removeAll() // Clear mock Storage
        CloudKitMock.defaultContainer.wipe()
        DownloadableThing.firebaseUserID = nil // Sign out of mock
        CloudKitMock.currentUserID = nil
    }
    
    func testStorageRef() {
        let genericFile = DownloadableThing()
        XCTAssertNil(genericFile.firebaseRef())
        
        DownloadableThing.firebaseUserID = "someUser"
        XCTAssertNotNil(genericFile.firebaseRef())
        XCTAssertEqual(genericFile.storage?.firebaseRef()?.path, genericFile.firebaseRef()?.path)
        if let genericRef = genericFile.firebaseRef() {
            let fileName = "\(genericFile.id).\(genericFile.fileExtension!)"
            XCTAssertEqual(genericRef.name, fileName)
        }
    }
    
    func testUploadProgressFraction() {
        var prog = UploadProgress(completedBytes: 100, totalBytes: 100)
        XCTAssertEqual(prog.fractionCompleted, 1, accuracy: 0.001)
        prog.completedBytes = 50
        XCTAssertEqual(prog.fractionCompleted, 0.5, accuracy: 0.001)
    }
    
    func testUploadNotAuthenticated() {
        let file = DownloadableThing()
        guard let payload = file.storage else {
            return XCTFail("SANITY FAIL: New DownloadableThing's storage is nil.")
        }
        
        // We should throw at first. We aren't signed in.
        XCTAssertThrowsError(try FirebaseFileUploader.uploadFile(payload, encryptingWithKey: nil), "User is signed in with id \(UploadableThing.firebaseUserID ?? "<null>")") { (error) in
            // Check the error's type
            if case .notAuthenticated = (error as? UploadError) { /* pass */ } else {
                XCTFail("Wrong error thrown: \(error)")
            }
        }
    }
    
    func runUploader<U>(_ uploader: U) where U: FileUploader {
        let progress = expectation(description: "\(U.self) operation should show progress")
        progress.assertForOverFulfill = false
        let shouldUpload = expectation(description: "\(U.self) operation should complete")
        
        var upload: AnyCancellable? = uploader
            .sink(receiveCompletion: { (completion) in
                if case .failure(let error) = completion {
                    XCTFail("\(error)")
                }
                shouldUpload.fulfill()
                
            }, receiveValue: { uploadProgress in
                progress.fulfill()
                XCTAssertGreaterThanOrEqual(uploadProgress.fractionCompleted, .zero)
            })
        
        wait(for: [progress, shouldUpload], timeout: 3, enforceOrder: true)
        if upload != nil {
            upload = nil
        }
    }
    
    func testFirebaseUploadSuccess() {
        let file = DownloadableThing()
        guard let payload = file.storage else {
            return XCTFail("SANITY FAIL: New DownloadableThing's storage was nil")
        }
        DownloadableThing.firebaseUserID = "someUser"
        
        do {
            let uploader = try FirebaseFileUploader.uploadFile(payload, encryptingWithKey: nil)
            runUploader(uploader)
            let path = file.firebaseRef()!.path
            XCTAssertNotNil(file.storage, "SANITY FAIL: Item lost its local payload")
            XCTAssertNotNil(FirebaseMock.uploadedData[path], "Upload failed")
            XCTAssertEqual(file.storage?.payload!, FirebaseMock.uploadedData[path])
            XCTAssertNotNil(file.storage?.payload,
                            "File needs to retain its local data; it hasn't been confirmed yet.")
            
        } catch {
            return XCTFail("\(error)")
        }
    }
    
    func testFirebaseEncryptedUpload() {
        let progress = expectation(description: "Upload operation should progress")
        progress.assertForOverFulfill = false
        let shouldUpload = expectation(description: "Upload operation should complete")
        
        let file = DownloadableThing()
        guard let payload = file.storage else {
            return XCTFail("SANITY FAIL: New DownloadableThing's storage was nil")
        }
        DownloadableThing.firebaseUserID = "someUser"
        let key = SymmetricKey(size: .bits256)
        
        var upload: AnyCancellable? = try! FirebaseFileUploader
            .uploadFile(payload, encryptingWithKey: key)
            .sink(receiveCompletion: { (completion) in
                shouldUpload.fulfill()
                if case .failure(let error) = completion {
                    return XCTFail("\(error)")
                }
                let path = file.firebaseRef()!.path
                // Encrypted data != raw data
                XCTAssertNotNil(file.storage, "SANITY FAIL: File lost its local payload")
                XCTAssertNotNil(FirebaseMock.uploadedData[path], "Upload failed")
                XCTAssertNotEqual(file.storage?.payload!, FirebaseMock.uploadedData[path])
                
                if let uploadedData = FirebaseMock.uploadedData[path] {
                    do {
                        let box = try ChaChaPoly.SealedBox(combined: uploadedData)
                        let decryptedData = try ChaChaPoly.open(box, using: key)
                        XCTAssertEqual(decryptedData, file.storage?.payload)
                    } catch {
                        XCTFail("Decryption failure: \(error)")
                    }
                }
                
            }, receiveValue: { uploadProgress in
                progress.fulfill()
                XCTAssertGreaterThanOrEqual(uploadProgress.fractionCompleted, .zero)
            })
        
        wait(for: [progress, shouldUpload], timeout: 2, enforceOrder: true)
        if upload != nil {
            upload = nil
        }
    }
    
    func runDownloader<D, U>(_ downloader: D,
                             after uploader: U,
                             expectingData expectedPayload: Data) where D: FileDownloader, U: FileUploader {
        // We first upload...
        // (We cannot easily mock this, as FirebaseFileUploader encrypts items as it works)
        let progress = expectation(description: "\(U.self) operation should show progress")
        progress.assertForOverFulfill = false
        let shouldUpload = expectation(description: "\(U.self) operation should complete")
        
        var upload: AnyCancellable? = uploader
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                if case .failure(let error) = completion {
                    XCTFail("\(error)")
                }
                shouldUpload.fulfill()
                
            }, receiveValue: { uploadProgress in
                progress.fulfill()
                XCTAssertGreaterThanOrEqual(uploadProgress.fractionCompleted, .zero)
            })
        
        wait(for: [progress, shouldUpload], timeout: 2, enforceOrder: true)
        if upload != nil {
            upload = nil
        }
        
        // Now we download. Compare the differences.
        let downloadExpectation = expectation(description: "\(D.self) operation should show progress")
        downloadExpectation.assertForOverFulfill = false
        let shouldDownload = expectation(description: "\(D.self) operation should complete")
        
        var download: AnyCancellable? = downloader
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                if case .failure(let error) = completion {
                    XCTFail("\(error)")
                }
                shouldDownload.fulfill()
                
            }, receiveValue: { downloadProgress in
                downloadExpectation.fulfill()
                XCTAssertGreaterThanOrEqual(downloadProgress.fractionCompleted ?? 0, .zero)
            })
        
        wait(for: [downloadExpectation, shouldDownload], timeout: 3, enforceOrder: true)
        if download != nil {
            download = nil
        }
    }
    
    func testFirebaseDownloadSuccess() {
        DownloadableThing.firebaseUserID = "someUser"
        
        let file = DownloadableThing()
        guard let payload = file.storage else {
            return XCTFail("SANITY FAIL: New DownloadableThing's storage was nil")
        }
        let encKey = SymmetricKey(size: .bits256)
        
        let uploader: FirebaseFileUploader<UploadableThing>
        do {
            uploader = try FirebaseFileUploader.uploadFile(payload, encryptingWithKey: encKey)
        } catch {
            return XCTFail("\(error)")
        }
        
        let downloadURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(file.id.uuidString, isDirectory: false)
            .appendingPathExtension(file.fileExtension ?? "")
        try? FileManager.default.removeItem(at: downloadURL)
        XCTAssertNoThrow(try FileManager.default
            .createDirectory(at: downloadURL.deletingLastPathComponent(),
                             withIntermediateDirectories: true))
        
        let downloader: FirebaseFileDownloader<DownloadableThing>
        do {
            downloader = try FirebaseFileDownloader.downloadFile(file, to: downloadURL, decryptingUsing: encKey)
        } catch {
            return XCTFail("\(error)")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadURL.path))
        runDownloader(downloader, after: uploader, expectingData: file.storage!.payload!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloadURL.path))
        
        XCTAssertNoThrow(try FileManager.default.removeItem(at: downloadURL.deletingLastPathComponent()))
    }
    
    func testFirebaseFileDeleteNonexistent() {
        DownloadableThing.firebaseUserID = "someUser"

        let file = DownloadableThing()
        let deletionExpec = expectation(description: "Firebase file deletion should fail for nonexistent file.")

        let deleter: FirebaseFileDeleter<DownloadableThing>

        do {
            deleter = try FirebaseFileDownloader.deleteFile(file)
        } catch {
            return XCTFail("\(error)")
        }

        var deletion: AnyCancellable? = deleter
            .receive(on: DispatchQueue.main)
            .sink(receiveCompletion: { (completion) in
                switch completion {
                case .failure(DownloadError.itemNotFound): break
                case .failure(let error):
                    XCTFail("Unexpected error '\(error)'")
                case .finished:
                    XCTFail("Deletion should fail on nonexistent file.")
                }
                deletionExpec.fulfill()

            }, receiveValue: { _ in })
        wait(for: [deletionExpec], timeout: 3)
        if deletion != nil {
            deletion = nil
        }
    }
    
}

