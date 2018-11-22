//
//  Copyright (c) 2018 Open Whisper Systems. All rights reserved.
//

import Foundation
import Photos
import PromiseKit

@objc(OWSImagePickerControllerDelegate)
protocol ImagePickerControllerDelegate {
    func imagePicker(_ imagePicker: ImagePickerGridController, didPickImageAttachments attachments: [SignalAttachment])
}

@objc(OWSImagePickerGridController)
class ImagePickerGridController: UICollectionViewController, PhotoLibraryDelegate, PhotoCollectionPickerDelegate, AttachmentApprovalViewControllerDelegate {

    @objc
    weak var delegate: ImagePickerControllerDelegate?

    private let library: PhotoLibrary = PhotoLibrary()
    private var photoCollection: PhotoCollection
    private var photoCollectionContents: PhotoCollectionContents
    private let photoMediaSize = PhotoMediaSize()

    var collectionViewFlowLayout: UICollectionViewFlowLayout

    private let titleLabel = UILabel()

    private var selectedIds = Set<String>()

    // This variable should only be accessed on the main thread.
    private var assetIdToCommentMap = [String: String]()

    init() {
        collectionViewFlowLayout = type(of: self).buildLayout()
        photoCollection = library.defaultPhotoCollection()
        photoCollectionContents = photoCollection.contents()

        super.init(collectionViewLayout: collectionViewFlowLayout)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()

        library.add(delegate: self)

        guard let collectionView = collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        collectionView.register(PhotoGridViewCell.self, forCellWithReuseIdentifier: PhotoGridViewCell.reuseIdentifier)

        view.backgroundColor = .ows_gray95

        if let navBar = self.navigationController?.navigationBar as? OWSNavigationBar {
            navBar.makeClear()
        } else {
            owsFailDebug("Invalid nav bar.")
        }

        let cancelButton = UIBarButtonItem(barButtonSystemItem: .stop,
                                           target: self,
                                           action: #selector(didPressCancel))
        cancelButton.tintColor = .ows_gray05
        navigationItem.leftBarButtonItem = cancelButton

        if #available(iOS 11, *) {
            titleLabel.text = photoCollection.localizedTitle()
            titleLabel.textColor = .ows_gray05
            titleLabel.font = UIFont.ows_dynamicTypeBody.ows_mediumWeight()

            let titleIconView = UIImageView()
            titleIconView.tintColor = .ows_gray05
            titleIconView.image = UIImage(named: "navbar_disclosure_down")?.withRenderingMode(.alwaysTemplate)

            let titleView = UIStackView(arrangedSubviews: [titleLabel, titleIconView])
            titleView.axis = .horizontal
            titleView.alignment = .center
            titleView.spacing = 5
            titleView.isUserInteractionEnabled = true
            titleView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(titleTapped)))
            navigationItem.titleView = titleView
        } else {
            navigationItem.title = photoCollection.localizedTitle()
        }

        let featureFlag_isMultiselectEnabled = true
        if featureFlag_isMultiselectEnabled {
            updateSelectButton()
        }

        collectionView.backgroundColor = .ows_gray95
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        updateLayout()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Determine the size of the thumbnails to request
        let scale = UIScreen.main.scale
        let cellSize = collectionViewFlowLayout.itemSize
        photoMediaSize.thumbnailSize = CGSize(width: cellSize.width * scale, height: cellSize.height * scale)

        reloadDataAndRestoreSelection()
    }

    private func reloadDataAndRestoreSelection() {
        guard let collectionView = collectionView else {
            owsFailDebug("Missing collectionView.")
            return
        }

        collectionView.reloadData()
        collectionView.layoutIfNeeded()

        let count = photoCollectionContents.count
        for index in 0..<count {
            let asset = photoCollectionContents.asset(at: index)
            let assetId = asset.localIdentifier
            if selectedIds.contains(assetId) {
                collectionView.selectItem(at: IndexPath(row: index, section: 0),
                                          animated: false, scrollPosition: [])
            }
        }
    }

    // MARK: - Actions

    @objc
    func didPressCancel(sender: UIBarButtonItem) {
        self.dismiss(animated: true)
    }

    // MARK: - Layout

    static let kInterItemSpacing: CGFloat = 2
    private class func buildLayout() -> UICollectionViewFlowLayout {
        let layout = UICollectionViewFlowLayout()

        if #available(iOS 11, *) {
            layout.sectionInsetReference = .fromSafeArea
        }
        layout.minimumInteritemSpacing = kInterItemSpacing
        layout.minimumLineSpacing = kInterItemSpacing
        layout.sectionHeadersPinToVisibleBounds = true

        return layout
    }

    func updateLayout() {
        let containerWidth: CGFloat
        if #available(iOS 11.0, *) {
            containerWidth = self.view.safeAreaLayoutGuide.layoutFrame.size.width
        } else {
            containerWidth = self.view.frame.size.width
        }

        let kItemsPerPortraitRow = 4
        let screenWidth = min(UIScreen.main.bounds.width, UIScreen.main.bounds.height)
        let approxItemWidth = screenWidth / CGFloat(kItemsPerPortraitRow)

        let itemCount = round(containerWidth / approxItemWidth)
        let spaceWidth = (itemCount + 1) * type(of: self).kInterItemSpacing
        let availableWidth = containerWidth - spaceWidth

        let itemWidth = floor(availableWidth / CGFloat(itemCount))
        let newItemSize = CGSize(width: itemWidth, height: itemWidth)

        if (newItemSize != collectionViewFlowLayout.itemSize) {
            collectionViewFlowLayout.itemSize = newItemSize
            collectionViewFlowLayout.invalidateLayout()
        }
    }

    // MARK: - Batch Selection

    lazy var doneButton: UIBarButtonItem = {
        return UIBarButtonItem(barButtonSystemItem: .done,
                               target: self,
                               action: #selector(didPressDone))
    }()

    lazy var selectButton: UIBarButtonItem = {
        return UIBarButtonItem(title: NSLocalizedString("BUTTON_SELECT", comment: "Button text to enable batch selection mode"),
                               style: .plain,
                               target: self,
                               action: #selector(didTapSelect))
    }()

    var isInBatchSelectMode = false {
        didSet {
            collectionView!.allowsMultipleSelection = isInBatchSelectMode
            updateSelectButton()
            updateDoneButton()
        }
    }

    @objc
    func didPressDone(_ sender: Any) {
        Logger.debug("")

        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        guard let indexPaths = collectionView.indexPathsForSelectedItems else {
            owsFailDebug("indexPaths was unexpectedly nil")
            return
        }

        let assets: [PHAsset] = indexPaths.compactMap { return photoCollectionContents.asset(at: $0.row) }
        complete(withAssets: assets)
    }

    func complete(withAssets assets: [PHAsset]) {
        let attachmentPromises: [Promise<SignalAttachment>] = assets.map({
            return photoCollectionContents.outgoingAttachment(for: $0)
        })
        when(fulfilled: attachmentPromises)
            .map { attachments in
            self.didComplete(withAttachments: attachments)
            }.retainUntilComplete()
    }

    private func didComplete(withAttachments attachments: [SignalAttachment]) {
        AssertIsOnMainThread()

        // If we re-enter image picking, do so in batch mode.
        isInBatchSelectMode = true

        for attachment in attachments {
            guard let assetId = attachment.assetId else {
                owsFailDebug("Attachment is missing asset id.")
                continue
            }
            // Link the attachment with its asset to ensure caption continuity.
            attachment.assetId = assetId
            // Restore any existing caption for this attachment.
            attachment.captionText = assetIdToCommentMap[assetId]
        }

        let vc = AttachmentApprovalViewController(mode: .sharedNavigation, attachments: attachments)
        vc.approvalDelegate = self
        navigationController?.pushViewController(vc, animated: true)
    }

    func updateDoneButton() {
        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        if let count = collectionView.indexPathsForSelectedItems?.count, count > 0 {
            self.doneButton.isEnabled = true
        } else {
            self.doneButton.isEnabled = false
        }
    }

    func updateSelectButton() {
        let button = isInBatchSelectMode ? doneButton : selectButton
        button.tintColor = .ows_gray05
        navigationItem.rightBarButtonItem = button
    }

    @objc
    func didTapSelect(_ sender: Any) {
        isInBatchSelectMode = true

        // disabled until at least one item is selected
        self.doneButton.isEnabled = false
    }

    @objc
    func didCancelSelect(_ sender: Any) {
        endSelectMode()
    }

    func endSelectMode() {
        isInBatchSelectMode = false

        guard let collectionView = self.collectionView else {
            owsFailDebug("collectionView was unexpectedly nil")
            return
        }

        // deselect any selected
        collectionView.indexPathsForSelectedItems?.forEach { collectionView.deselectItem(at: $0, animated: false)}
    }

    // MARK: - PhotoLibraryDelegate

    func photoLibraryDidChange(_ photoLibrary: PhotoLibrary) {
        // We only want to let users select assets
        // from a single collection.
        selectedIds.removeAll()

        reloadDataAndRestoreSelection()
    }

    // MARK: - PhotoCollectionPickerDelegate

    func photoCollectionPicker(_ photoCollectionPicker: PhotoCollectionPickerController, didPickCollection collection: PhotoCollection) {
        photoCollection = collection
        photoCollectionContents = photoCollection.contents()

        if #available(iOS 11, *) {
            titleLabel.text = photoCollection.localizedTitle()
        } else {
            navigationItem.title = photoCollection.localizedTitle()
        }

        reloadDataAndRestoreSelection()
    }

    // MARK: - Event Handlers

    @objc func titleTapped(sender: UIGestureRecognizer) {
        guard sender.state == .recognized else {
            return
        }
        let view = PhotoCollectionPickerController(library: library,
                                                   previousPhotoCollection: photoCollection,
                                                   collectionDelegate: self)
        let nav = OWSNavigationController(rootViewController: view)
        self.present(nav, animated: true, completion: nil)
    }

    // MARK: - UICollectionView

    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {

        let asset = photoCollectionContents.asset(at: indexPath.item)
        let assetId = asset.localIdentifier
        selectedIds.insert(assetId)

        if isInBatchSelectMode {
            updateDoneButton()
        } else {
            complete(withAssets: [asset])
        }
    }

    public override func collectionView(_ collectionView: UICollectionView, didDeselectItemAt indexPath: IndexPath) {
        Logger.debug("")

        let asset = photoCollectionContents.asset(at: indexPath.item)
        let assetId = asset.localIdentifier
        selectedIds.remove(assetId)

        if isInBatchSelectMode {
            updateDoneButton()
        }
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        return photoCollectionContents.count
    }

    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(withReuseIdentifier: PhotoGridViewCell.reuseIdentifier, for: indexPath) as? PhotoGridViewCell else {
            owsFail("cell was unexpectedly nil")
        }
        cell.loadingColor = UIColor(white: 0.2, alpha: 1)
        let assetItem = photoCollectionContents.assetItem(at: indexPath.item, photoMediaSize: photoMediaSize)
        cell.configure(item: assetItem)

        let assetId = assetItem.asset.localIdentifier
        let isSelected = selectedIds.contains(assetId)
        cell.isSelected = isSelected

        return cell
    }

    // MARK: - AttachmentApprovalViewControllerDelegate

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didApproveAttachments attachments: [SignalAttachment]) {
        self.dismiss(animated: true) {
            self.delegate?.imagePicker(self, didPickImageAttachments: attachments)
        }
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, didCancelAttachments attachments: [SignalAttachment]) {
        navigationController?.popToViewController(self, animated: true)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, addMoreToAttachments attachments: [SignalAttachment]) {
        navigationController?.popToViewController(self, animated: true)
    }

    func attachmentApproval(_ attachmentApproval: AttachmentApprovalViewController, changedCaptionOfAttachment attachment: SignalAttachment) {
        AssertIsOnMainThread()

        guard let assetId = attachment.assetId else {
            owsFailDebug("Attachment missing source id.")
            return
        }
        guard let captionText = attachment.captionText, captionText.count > 0 else {
            assetIdToCommentMap.removeValue(forKey: assetId)
            return
        }
        assetIdToCommentMap[assetId] = captionText
    }
}
