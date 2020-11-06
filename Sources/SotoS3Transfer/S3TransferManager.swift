//===----------------------------------------------------------------------===//
//
// This source file is part of the Soto for AWS open source project
//
// Copyright (c) 2017-2020 the Soto project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Soto project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import Foundation
import Logging
import NIO
import SotoS3

/// S3 Transfer manager. Transfers files/folders back and forth between S3 and your local file system
public struct S3TransferManager {
    // Configuration for S3 Transfer Manager
    public struct Configuration {
        // size file has to be before using multipart upload
        let multipartThreshold: Int
        // size of each multipart part upload
        let multipartPartSize: Int
        
        public init(
            multipartThreshold: Int = 8 * 1024 * 1024,
            multipartPartSize: Int = 8 * 1024 * 1024
        ) {
            precondition(multipartThreshold >= 5 * 1024 * 1024, "Multipart upload threshold is required to be greater than 5MB")
            precondition(multipartThreshold >= multipartPartSize, "Multipart upload threshold is required to be greater than the multipart part size")
            self.multipartThreshold = multipartThreshold
            self.multipartPartSize = multipartPartSize
        }
    }

    public enum Error: Swift.Error {
        case failedToCreateFolder(String)
        case failedToEnumerateFolder(String)
    }

    let s3: S3
    let threadPoolProvider: S3.ThreadPoolProvider
    let threadPool: NIOThreadPool
    let fileIO: NonBlockingFileIO
    let configuration: Configuration
    let logger: Logger

    /// Initialize S3 Transfer manager.
    /// - Parameters:
    ///   - s3: S3 service object from Soto
    ///   - threadPoolProvider: Thread pool provider for file operations, Either create a new pool, or supply you have already
    ///   - configuration: transfer manager configuration
    ///   - logger: Logger
    public init(
        s3: S3,
        threadPoolProvider: S3.ThreadPoolProvider,
        configuration: Configuration = Configuration(),
        logger: Logger = AWSClient.loggingDisabled
    ) {
        self.s3 = s3
        self.threadPoolProvider = threadPoolProvider

        switch threadPoolProvider {
        case .createNew:
            self.threadPool = NIOThreadPool(numberOfThreads: 2)
            self.threadPool.start()
        case .shared(let sharedPool):
            self.threadPool = sharedPool
        }
        self.fileIO = NonBlockingFileIO(threadPool: self.threadPool)
        self.configuration = configuration
        self.logger = logger
    }

    /// Shutdown S3 Transfer manager. Delete thread pool, if one was created by manager
    public func syncShutdown() throws {
        if case .createNew = self.threadPoolProvider {
            threadPool.shutdownGracefully { _ in }
        }
    }

    /// Copy from local file, to S3 file
    /// - Parameters:
    ///   - from: local filename
    ///   - to: S3 file
    ///   - progress: progress function, updated with value from 0 to 1 based on how much we have uploaded
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from: String, to: S3File, progress: @escaping (Double) throws -> Void = { _ in }) -> EventLoopFuture<Void> {
        self.logger.info("Copy from: \(from) to \(to)")
        let eventLoop = self.s3.eventLoopGroup.next()
        return self.fileIO.openFile(path: from, eventLoop: eventLoop)
            .flatMap { fileHandle, fileRegion in
                let fileSize = fileRegion.readableBytes
                // if file size is greater than multipart threshold then use multipart upload for uploading the file
                if fileSize > self.configuration.multipartThreshold {
                    let request = S3.CreateMultipartUploadRequest(bucket: to.bucket, key: to.path)
                    return s3.multipartUpload(
                        request,
                        partSize: self.configuration.multipartPartSize,
                        fileHandle: fileHandle,
                        fileIO: self.fileIO,
                        uploadSize: fileSize,
                        abortOnFail: true,
                        on: eventLoop,
                        progress: progress
                    )
                    .map { _ in }
                    .closeFileHandle(fileHandle)
                } else {
                    let payload: AWSPayload = .fileHandle(fileHandle, offset: 0, size: fileSize, fileIO: self.fileIO) { downloaded in
                        try progress(Double(downloaded) / Double(fileSize))
                    }
                    let request = S3.PutObjectRequest(body: payload, bucket: to.bucket, key: to.path)
                    return self.s3.putObject(request, on: eventLoop).map { _ in }.closeFileHandle(fileHandle)
                }
            }
    }

    /// Copy from S3 file, to local file
    /// - Parameters:
    ///   - from: S3 file
    ///   - to: local filename
    ///   - progress: progress function, updated with value from 0 to 1 based on how much we have uploaded
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from: S3File, to: String, progress: @escaping (Double) throws -> Void = { _ in }) -> EventLoopFuture<Void> {
        self.logger.info("Copy from: \(from) to \(to)")
        let eventLoop = self.s3.eventLoopGroup.next()
        var bytesDownloaded = 0

        return self.threadPool.runIfActive(eventLoop: eventLoop) { () -> Void in
            // create folder to place file in, if it doesn't exist already
            let folder: String
            var isDirectory: ObjCBool = false
            if let lastSlash = to.lastIndex(of: "/") {
                folder = String(to[to.startIndex..<lastSlash])
            } else {
                folder = to
            }
            if FileManager.default.fileExists(atPath: folder, isDirectory: &isDirectory) {
                guard isDirectory.boolValue else { throw Error.failedToCreateFolder(folder) }
            } else {
                try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            }
        }.flatMap {
            self.fileIO.openFile(path: to, mode: .write, flags: .allowFileCreation(), eventLoop: eventLoop)
        }.flatMap { fileHandle -> EventLoopFuture<S3.GetObjectOutput> in
            // get filesize so we can calculate progress
            return self.s3.headObject(.init(bucket: from.bucket, key: from.path))
                .flatMap { response in
                    let fileSize = response.contentLength ?? 1
                    let request = S3.GetObjectRequest(bucket: from.bucket, key: from.path)
                    return self.s3.getObjectStreaming(request, on: eventLoop) { byteBuffer, eventLoop in
                        let bufferSize = byteBuffer.readableBytes
                        return self.fileIO.write(fileHandle: fileHandle, buffer: byteBuffer, eventLoop: eventLoop).flatMapThrowing { _ in
                            bytesDownloaded += bufferSize
                            try progress(Double(bytesDownloaded) / Double(fileSize))
                        }
                    }
                }
                .closeFileHandle(fileHandle)
        }.map { _ in }
    }

    /// Copy from S3 file, to S3 file
    /// - Parameters:
    ///   - from: source S3 file
    ///   - to: destination S3 file
    ///   - progress: progress function, updated with value from 0 to 1 based on how much we have uploaded
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from: S3File, to: S3File, progress: @escaping (Double) throws -> Void = { _ in }) -> EventLoopFuture<Void> {
        self.logger.info("Copy from: \(from) to \(to)")
        let request = S3.CopyObjectRequest(bucket: to.bucket, copySource: "/\(from.bucket)/\(from.path)", key: to.path)
        return self.s3.copyObject(request)
            .map { _ in }
    }

    /// Copy from local folder, to S3 folder
    /// - Parameters:
    ///   - from: local folder
    ///   - to: Path to S3 folder
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from folder: String, to s3Folder: S3Folder) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()
        return listFiles(in: folder)
            .flatMap { files in
                let transfers = Self.targetFiles(files: files, from: folder, to: s3Folder)
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.name, to: $0.to) }
                return EventLoopFuture.andAllComplete(transferFutures, on: eventLoop).map { _ in }
            }
    }

    /// Copy from S3 folder, to local folder
    /// - Parameters:
    ///   - from: Path to S3 folder
    ///   - to: Local folder
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from s3Folder: S3Folder, to folder: String) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()
        return listFiles(in: s3Folder)
            .flatMap { files in
                let transfers = Self.targetFiles(files: files, from: s3Folder, to: folder)
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.file, to: $0.to) }
                return EventLoopFuture.andAllComplete(transferFutures, on: eventLoop).map { _ in }
            }
    }

    /// Copy from S3 folder, to S3 folder
    /// - Parameters:
    ///   - from: Path to source S3 folder
    ///   - to: Path to destination S3 folder
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func copy(from srcFolder: S3Folder, to destFolder: S3Folder) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()
        return listFiles(in: srcFolder)
            .flatMap { files in
                let transfers = Self.targetFiles(files: files, from: srcFolder, to: destFolder)
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.file, to: $0.to) }
                return EventLoopFuture.andAllComplete(transferFutures, on: eventLoop).map { _ in }
            }
    }

    /// Sync from local folder, to S3 folder. Copies files across unless the file already exists in S3 folder, or file in S3 is newer. Added flag to
    /// delete files on S3 that don't exist locally
    ///
    /// - Parameters:
    ///   - from: Local folder
    ///   - to: Path to destination S3 folder
    ///   - delete: Should we delete files on S3 that don't exists locally
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func sync(from folder: String, to s3Folder: S3Folder, delete: Bool) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()

        return listFiles(in: folder).and(listFiles(in: s3Folder))
            .flatMap { files, s3Files in
                let targetFiles = Self.targetFiles(files: files, from: folder, to: s3Folder)
                let transfers = targetFiles.compactMap { transfer -> (from: FileDescriptor, to: S3File)? in
                    // does file exist on S3
                    guard let s3File = s3Files.first(where: { $0.file.path == transfer.to.path }) else { return transfer }
                    // does file on S3 have a later date
                    guard s3File.modificationDate > transfer.from.modificationDate else { return transfer }
                    return nil
                }
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.name, to: $0.to) }
                // construct list of files to delete, if we are doing deletion
                var deleteFutures: [EventLoopFuture<Void>] = []
                if delete == true {
                    let deletions = s3Files.compactMap { s3File -> S3File? in
                        if targetFiles.first(where: { $0.to.path == s3File.file.path }) == nil {
                            return s3File.file
                        } else {
                            return nil
                        }
                    }
                    deleteFutures = deletions.map { self.delete($0) }
                }
                return EventLoopFuture.whenAllSucceed(transferFutures + deleteFutures, on: eventLoop).map { _ in }
            }
    }

    /// Sync from S3 folder, to local folder. Download files from S3 unless the file already exists in local folder, or local file is newer. Added flag to
    /// delete files locally that don't exist in S3.
    ///
    /// - Parameters:
    ///   - from: Path to source S3 folder
    ///   - to: Local folder
    ///   - delete: Should we delete files locally that don't exists in S3
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func sync(from s3Folder: S3Folder, to folder: String, delete: Bool) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()

        return listFiles(in: folder).and(listFiles(in: s3Folder))
            .flatMap { files, s3Files in
                let targetFiles = Self.targetFiles(files: s3Files, from: s3Folder, to: folder)
                let transfers = targetFiles.compactMap { transfer -> (from: S3FileDescriptor, to: String)? in
                    // does file exist locally
                    guard let file = files.first(where: { $0.name == transfer.to }) else { return transfer }
                    // does local file have a later date
                    guard file.modificationDate > transfer.from.modificationDate else { return transfer }
                    return nil
                }
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.file, to: $0.to) }
                // construct list of files to delete, if we are doing deletion
                var deleteFutures: [EventLoopFuture<Void>] = []
                if delete == true {
                    let deletions = files.compactMap { file -> String? in
                        if targetFiles.first(where: { $0.to == file.name }) == nil {
                            return file.name
                        } else {
                            return nil
                        }
                    }
                    deleteFutures = deletions.map { self.delete($0) }
                }
                return EventLoopFuture.whenAllSucceed(transferFutures + deleteFutures, on: eventLoop).map { _ in }
            }
    }

    /// Sync from S3 folder, to another S3 folder. Copy files from S3 folder unless the file already exists in destination folder, or destination file is newer. Added flag to
    /// delete files from destination folder that don't exist in source folder.
    ///
    /// - Parameters:
    ///   - from: Path to source S3 folder
    ///   - to: Local folder
    ///   - delete: Should we delete files locally that don't exists in S3
    /// - Returns: EventLoopFuture fulfilled when operation is complete
    public func sync(from srcFolder: S3Folder, to destFolder: S3Folder, delete: Bool) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()

        return listFiles(in: srcFolder).and(listFiles(in: destFolder))
            .flatMap { srcFiles, destFiles in
                let targetFiles = Self.targetFiles(files: srcFiles, from: srcFolder, to: destFolder)
                let transfers = targetFiles.compactMap { transfer -> (from: S3FileDescriptor, to: S3File)? in
                    // does file exist in destination folder
                    guard let file = destFiles.first(where: { $0.file.path == transfer.to.path }) else { return transfer }
                    // does local file have a later date
                    guard file.modificationDate > transfer.from.modificationDate else { return transfer }
                    return nil
                }
                let transferFutures: [EventLoopFuture<Void>] = transfers.map { self.copy(from: $0.from.file, to: $0.to) }
                // construct list of files to delete, if we are doing deletion
                var deleteFutures: [EventLoopFuture<Void>] = []
                if delete == true {
                    let deletions = destFiles.compactMap { file -> S3File? in
                        if targetFiles.first(where: { $0.to.path == file.file.path }) == nil {
                            return file.file
                        } else {
                            return nil
                        }
                    }
                    deleteFutures = deletions.map { self.delete($0) }
                }
                return EventLoopFuture.whenAllSucceed(transferFutures + deleteFutures, on: eventLoop).map { _ in }
            }
    }

    /// delete a file on S3
    public func delete(_ s3File: S3File) -> EventLoopFuture<Void> {
        self.logger.info("Deleting \(s3File)")
        return self.s3.deleteObject(.init(bucket: s3File.bucket, key: s3File.path)).map { _ in }
    }

    /// delete a folder on S3
    public func delete(_ s3Folder: S3Folder) -> EventLoopFuture<Void> {
        let eventLoop = self.s3.eventLoopGroup.next()
        return listFiles(in: s3Folder)
            .flatMap { files in
                let deleteFutures = files.map { self.delete($0.file) }
                return EventLoopFuture.whenAllSucceed(deleteFutures, on: eventLoop).map { _ in }
            }
    }
}

extension S3TransferManager {
    struct FileDescriptor {
        let name: String
        let modificationDate: Date
    }

    struct S3FileDescriptor {
        let file: S3File
        let modificationDate: Date
    }

    /// List files in local folder
    func listFiles(in folder: String) -> EventLoopFuture<[FileDescriptor]> {
        let eventLoop = self.s3.eventLoopGroup.next()
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            var files: [FileDescriptor] = []
            let path = URL(fileURLWithPath: folder)
            guard let fileEnumerator = FileManager.default.enumerator(
                at: path,
                includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                options: .skipsHiddenFiles
            ) else {
                throw Error.failedToEnumerateFolder(folder)
            }
            while let file = fileEnumerator.nextObject() as? URL {
                let path = file.path
                var isDirectory: ObjCBool = false
                // ignore if it is a directory
                _ = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                guard !isDirectory.boolValue else { continue }
                // get modification data and append along with file name
                let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
                guard let modificationDate = attributes[.modificationDate] as? Date else { continue }
                files.append(.init(name: file.path, modificationDate: modificationDate))
            }
            return files
        }
    }

    /// List files in S3 folder
    func listFiles(in folder: S3Folder) -> EventLoopFuture<[S3FileDescriptor]> {
        let request = S3.ListObjectsV2Request(bucket: folder.bucket, prefix: folder.path)
        return self.s3.listObjectsV2Paginator(request, []) { accumulator, response, eventLoop in
            let files: [S3FileDescriptor] = response.contents?.compactMap {
                guard let key = $0.key,
                    let lastModified = $0.lastModified else { return nil }
                return S3FileDescriptor(file: S3File(bucket: folder.bucket, path: key), modificationDate: lastModified)
            } ?? []
            return eventLoop.makeSucceededFuture((true, accumulator + files))
        }
    }

    /// delete a local file
    func delete(_ file: String) -> EventLoopFuture<Void> {
        self.logger.info("Deleting \(file)")
        let eventLoop = self.s3.eventLoopGroup.next()
        return self.threadPool.runIfActive(eventLoop: eventLoop) {
            try FileManager.default.removeItem(atPath: file)
        }
    }

    /// convert file descriptors to equivalent S3 file descriptors when copying one folder to another. Function assumes the files have srcFolder prefixed
    static func targetFiles(files: [FileDescriptor], from srcFolder: String, to destFolder: S3Folder) -> [(from: FileDescriptor, to: S3File)] {
        let srcFolder = srcFolder.appendingSuffixIfNeeded("/")
        return files.map { file in
            let pathRelative = file.name.removingPrefix(srcFolder)
            return (from: file, to: S3File(bucket: destFolder.bucket, path: destFolder.path + pathRelative))
        }
    }

    /// convert S3 file descriptors to equivalent file descriptors when copying files from the S3 folder to a local folder. Function assumes the S3 files have
    /// the source path prefixed
    static func targetFiles(files: [S3FileDescriptor], from srcFolder: S3Folder, to destFolder: String) -> [(from: S3FileDescriptor, to: String)] {
        let destFolder = destFolder.appendingSuffixIfNeeded("/")
        return files.map { file in
            let pathRelative = file.file.path.removingPrefix(srcFolder.path)
            return (from: file, to: destFolder + pathRelative)
        }
    }

    /// convert S3 file descriptors to equivalent S3 file descriptors when copying files from the S3 folder to another S3 folder. Function assumes the S3 files have
    /// the source path prefixed
    static func targetFiles(files: [S3FileDescriptor], from srcFolder: S3Folder, to destFolder: S3Folder) -> [(from: S3FileDescriptor, to: S3File)] {
        return files.map { file in
            let pathRelative = file.file.path.removingPrefix(srcFolder.path)
            return (from: file, to: .init(bucket: destFolder.bucket, path: destFolder.path + pathRelative))
        }
    }
}

extension EventLoopFuture {
    func closeFileHandle(_ fileHandle: NIOFileHandle) -> EventLoopFuture<Value> {
        return self.flatMapErrorThrowing { error in
            try fileHandle.close()
            throw error
        }
        .flatMapThrowing { rt -> Value in
            try fileHandle.close()
            return rt
        }
    }
}
