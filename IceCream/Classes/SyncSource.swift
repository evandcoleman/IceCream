//
//  SyncSource.swift
//  IceCream
//
//  Created by David Collado on 1/5/18.
//

import Foundation
import RealmSwift
import CloudKit

public final class SyncSource<T: Object & CKRecordConvertible & CKRecordRecoverable>: Syncable {

    /// Notifications are delivered as long as a reference is held to the returned notification token. You should keep a strong reference to this token on the class registering for updates, as notifications are automatically unregistered when the notification token is deallocated.
    /// For more, reference is here: https://realm.io/docs/swift/latest/#notifications
    private var notificationToken: NotificationToken?

    private let errorHandler = ErrorHandler()
    
    public var sync: ((_ recordsToStore: [CKRecord], _ recordIDsToDelete: [CKRecordID]) -> ())?
    
    /// We recommand process the initialization when app launches
    public init() { }
}

// MARK: - Zone information

extension SyncSource {
    public var customZoneID: CKRecordZoneID {
        return T.customZoneID
    }

    public var zoneChangesToken: CKServerChangeToken? {
        get {
            /// For the very first time when launching, the token will be nil and the server will be giving everything on the Cloud to client
            /// In other situation just get the unarchive the data object
            guard let tokenData = UserDefaults.standard.object(forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value) as? Data else { return nil }
            return NSKeyedUnarchiver.unarchiveObject(with: tokenData) as? CKServerChangeToken
        }
        set {
            guard let n = newValue else {
                UserDefaults.standard.removeObject(forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value)
                return
            }
            let data = NSKeyedArchiver.archivedData(withRootObject: n)
            UserDefaults.standard.set(data, forKey: T.className() + IceCreamKey.zoneChangesTokenKey.value)
        }
    }

    public var recordType: String {
        return T.recordType
    }

    public var isCustomZoneCreated: Bool {
        get {
            guard let flag = UserDefaults.standard.object(forKey: T.className() + IceCreamKey.hasCustomZoneCreatedKey.value) as? Bool else { return false }
            return flag
        }
        set {
            UserDefaults.standard.set(newValue, forKey: T.className() + IceCreamKey.hasCustomZoneCreatedKey.value)
        }
    }
}

// MARK: - Realm database methods

extension SyncSource {
    public func add(record: CKRecord) {
        guard let object = T().parseFromRecord(record: record)  else {
            print("There is something wrong with the converson from cloud record to local object")
            return
        }

        DispatchQueue.main.async {
            let realm = try! Realm()

            /// If your model class includes a primary key, you can have Realm intelligently update or add objects based off of their primary key values using Realm().add(_:update:).
            /// https://realm.io/docs/swift/latest/#objects-with-primary-keys
            realm.beginWrite()
            realm.add(object, update: true)
            if let token = `self`.notificationToken {
                try! realm.commitWrite(withoutNotifying: [token])
            } else {
                try! realm.commitWrite()
            }
        }
    }

    public func delete(recordID: CKRecordID) {
        DispatchQueue.main.async {
            let realm = try! Realm()
            guard let object = realm.object(ofType: T.self, forPrimaryKey: recordID.recordName) else {
                // Not found in local
                return
            }
            CreamAsset.deleteCreamAssetFile(with: recordID.recordName)
            realm.beginWrite()
            realm.delete(object)
            if let token = `self`.notificationToken {
                try! realm.commitWrite(withoutNotifying: [token])
            } else {
                try! realm.commitWrite()
            }
        }
    }

    /// When you commit a write transaction to a Realm, all other instances of that Realm will be notified, and be updated automatically.
    /// For more: https://realm.io/docs/swift/latest/#writes
    public func registerLocalDatabase() {
        let objects = Cream<T>().realm.objects(T.self)
        notificationToken = objects.observe({ [weak self](changes) in
            guard let `self` = self else { return }

            switch changes {
            case .initial(let collection):
                print("Inited:" + "\(collection)")
                break
            case .update(let collection, let deletions, let insertions, let modifications):
                print("collections:" + "\(collection)")
                print("deletions:" + "\(deletions)")
                print("insertions:" + "\(insertions)")
                print("modifications:" + "\(modifications)")

                let objectsToStore = (insertions + modifications).filter { $0 < collection.count }.map { collection[$0] }.filter{ !$0.isDeleted }
                let objectsToDelete = modifications.filter { $0 < collection.count }.map{ collection[$0] }.filter { $0.isDeleted }
                `self`.syncObjectsToCloudKit(objectsToStore: objectsToStore, objectsToDelete: objectsToDelete)

            case .error(_):
                break
            }
        })
    }

    public func cleanUp() {
        let cream = Cream<T>()
        do {
            try cream.deletePreviousSoftDeleteObjects(notNotifying: notificationToken)
        } catch {
            // Error handles here
        }
    }
}

// MARK: - Public methods

extension SyncSource {
    // This method is commonly used when you want to push your datas to CloudKit manually
    // In most cases, you don't need this
    public func syncObjectsToCloudKit(objectsToStore: [T], objectsToDelete: [T] = []) {
        guard objectsToStore.count > 0 || objectsToDelete.count > 0 else { return }

        let recordsToStore = objectsToStore.map{ $0.record }
        let recordIDsToDelete = objectsToDelete.map{ $0.recordID }
        
        sync?(recordsToStore, recordIDsToDelete)
    }
}
