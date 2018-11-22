//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Photos
import PromiseKit

protocol PhotoLibraryDelegate: class {
    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary)
}

class PhotoMediaSize {
    var thumbnailSize: CGSize

    init() {
        self.thumbnailSize = .zero
    }

    init(thumbnailSize: CGSize) {
        self.thumbnailSize = thumbnailSize
    }
}

class PhotoPickerAssetItem: PhotoGridItem {

    let asset: PHAsset
    let album: PhotoCollectionContents
    let photoMediaSize: PhotoMediaSize

    init(asset: PHAsset, album: PhotoCollectionContents, photoMediaSize: PhotoMediaSize) {
        self.asset = asset
        self.album = album
        self.photoMediaSize = photoMediaSize
    }

    // MARK: PhotoGridItem

    var type: PhotoGridItemType {
        if asset.mediaType == .video {
            return .video
        }

        // TODO show GIF badge?

        return  .photo
    }

    func asyncThumbnail(completion: @escaping (UIImage?) -> Void) -> UIImage? {
        album.requestThumbnail(for: self.asset, thumbnailSize: photoMediaSize.thumbnailSize) { image, _ in
            completion(image)
        }
        return nil
    }
}

class PhotoCollectionContents {

    let fetchResult: PHFetchResult<PHAsset>
    let localizedTitle: String?

    enum PhotoLibraryError: Error {
        case assertionError(description: String)
        case unsupportedMediaType

    }

    init(fetchResult: PHFetchResult<PHAsset>, localizedTitle: String?) {
        self.fetchResult = fetchResult
        self.localizedTitle = localizedTitle
    }

    var count: Int {
        return fetchResult.count
    }

    private let imageManager = PHCachingImageManager()

    func asset(at index: Int) -> PHAsset {
        return fetchResult.object(at: index)
    }

    func assetItem(at index: Int, photoMediaSize: PhotoMediaSize) -> PhotoPickerAssetItem {
        let mediaAsset = asset(at: index)
        return PhotoPickerAssetItem(asset: mediaAsset, album: self, photoMediaSize: photoMediaSize)
    }

    // MARK: ImageManager

    func requestThumbnail(for asset: PHAsset, thumbnailSize: CGSize, resultHandler: @escaping (UIImage?, [AnyHashable: Any]?) -> Void) {
        _ = imageManager.requestImage(for: asset, targetSize: thumbnailSize, contentMode: .aspectFill, options: nil, resultHandler: resultHandler)
    }

    private func requestImageDataSource(for asset: PHAsset) -> Promise<(dataSource: DataSource, dataUTI: String)> {
        return Promise { resolver in
            _ = imageManager.requestImageData(for: asset, options: nil) { imageData, dataUTI, _, _ in
                guard let imageData = imageData else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "imageData was unexpectedly nil"))
                    return
                }

                guard let dataUTI = dataUTI else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "dataUTI was unexpectedly nil"))
                    return
                }

                guard let dataSource = DataSourceValue.dataSource(with: imageData, utiType: dataUTI) else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "dataSource was unexpectedly nil"))
                    return
                }

                resolver.fulfill((dataSource: dataSource, dataUTI: dataUTI))
            }
        }
    }

    private func requestVideoDataSource(for asset: PHAsset) -> Promise<(dataSource: DataSource, dataUTI: String)> {
        return Promise { resolver in

            _ = imageManager.requestExportSession(forVideo: asset, options: nil, exportPreset: AVAssetExportPresetMediumQuality) { exportSession, _ in

                guard let exportSession = exportSession else {
                    resolver.reject(PhotoLibraryError.assertionError(description: "exportSession was unexpectedly nil"))
                    return
                }

                exportSession.outputFileType = AVFileType.mp4
                exportSession.metadataItemFilter = AVMetadataItemFilter.forSharing()

                let exportPath = OWSFileSystem.temporaryFilePath(withFileExtension: "mp4")
                let exportURL = URL(fileURLWithPath: exportPath)
                exportSession.outputURL = exportURL

                Logger.debug("starting video export")
                exportSession.exportAsynchronously {
                    Logger.debug("Completed video export")

                    guard let dataSource = DataSourcePath.dataSource(with: exportURL, shouldDeleteOnDeallocation: true) else {
                        resolver.reject(PhotoLibraryError.assertionError(description: "Failed to build data source for exported video URL"))
                        return
                    }

                    resolver.fulfill((dataSource: dataSource, dataUTI: kUTTypeMPEG4 as String))
                }
            }
        }
    }

    func outgoingAttachment(for asset: PHAsset) -> Promise<SignalAttachment> {
        switch asset.mediaType {
        case .image:
            return requestImageDataSource(for: asset).map { (dataSource: DataSource, dataUTI: String) in
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: dataUTI, imageQuality: .medium)
                attachment.assetId = asset.localIdentifier
                return attachment
            }
        case .video:
            return requestVideoDataSource(for: asset).map { (dataSource: DataSource, dataUTI: String) in
                let attachment = SignalAttachment.attachment(dataSource: dataSource, dataUTI: dataUTI)
                attachment.assetId = asset.localIdentifier
                return attachment
            }
        default:
            return Promise(error: PhotoLibraryError.unsupportedMediaType)
        }
    }
}

class PhotoCollection {
    private let collection: PHAssetCollection

    init(collection: PHAssetCollection) {
        self.collection = collection
    }

    func localizedTitle() -> String {
        guard let localizedTitle = collection.localizedTitle?.stripped,
            localizedTitle.count > 0 else {
            return NSLocalizedString("PHOTO_PICKER_UNNAMED_COLLECTION", comment: "label for system photo collections which have no name.")
        }
        return localizedTitle
    }

    func contents() -> PhotoCollectionContents {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let fetchResult = PHAsset.fetchAssets(in: collection, options: options)

        return PhotoCollectionContents(fetchResult: fetchResult, localizedTitle: localizedTitle())
    }
}

class PhotoLibrary: NSObject, PHPhotoLibraryChangeObserver {
    typealias WeakDelegate = Weak<PhotoLibraryDelegate>
    var delegates = [WeakDelegate]()

    public func add(delegate: PhotoLibraryDelegate) {
        delegates.append(WeakDelegate(value: delegate))
    }

    var assetCollection: PHAssetCollection!

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        DispatchQueue.main.async {
            for weakDelegate in self.delegates {
                weakDelegate.value?.photoLibraryDidChange(self)
            }
        }
    }

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func defaultPhotoCollection() -> PhotoCollection {
        guard let photoCollection = allPhotoCollections().first else {
            owsFail("Could not locate Camera Roll.")
        }
        return photoCollection
    }

    func allPhotoCollections() -> [PhotoCollection] {
        var collections = [PhotoCollection]()
        var collectionIds = Set<String>()

        let processPHCollection: (PHCollection) -> Void = { (collection) in
            // De-duplicate by id.
            let collectionId = collection.localIdentifier
            guard !collectionIds.contains(collectionId) else {
                return
            }
            collectionIds.insert(collectionId)

            guard let assetCollection = collection as? PHAssetCollection else {
                owsFailDebug("Asset collection has unexpected type: \(type(of: collection))")
                return
            }
            let photoCollection = PhotoCollection(collection: assetCollection)
            // Hide empty collections.
            guard photoCollection.contents().count > 0 else {
                return
            }
            collections.append(photoCollection)
        }
        let processPHAssetCollections: (PHFetchResult<PHAssetCollection>) -> Void = { (fetchResult) in
            for index in 0..<fetchResult.count {
                processPHCollection(fetchResult.object(at: index))
            }
        }
        let processPHCollections: (PHFetchResult<PHCollection>) -> Void = { (fetchResult) in
            for index in 0..<fetchResult.count {
                processPHCollection(fetchResult.object(at: index))
            }
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "endDate", ascending: true)]
        // Try to add "Camera Roll" first.
        processPHAssetCollections(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .smartAlbumUserLibrary, options: fetchOptions))
        // User-created albums.
        processPHCollections(PHAssetCollection.fetchTopLevelUserCollections(with: fetchOptions))
        // Smart albums.
        processPHAssetCollections(PHAssetCollection.fetchAssetCollections(with: .smartAlbum, subtype: .albumRegular, options: fetchOptions))

        return collections
    }
}
