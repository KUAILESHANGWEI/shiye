# App Review notes

Shiye is a personal website, bookmark, note and file organizer for iPhone and Mac.

On first launch, create a local launch password of your choice and confirm it. This password protects access to the interface on that device. You can change it in System Settings. The app does not require an app account or a developer-provided demo account.

To review the primary features, create a website group, save a website or bookmark, write a note with an optional pasted image, and import a file you choose. Notes and files support one-to-three-star ratings. Files can be previewed using the system viewer or exported using the system share/save interface. Link metadata depends on the destination website and may be restricted by the website.

The primary collection features save locally. To review cross-device synchronization, enable iCloud on an iPhone and Mac signed into the same iCloud account. The app uses NSPersistentCloudKitContainer with a private CloudKit database. CloudKit production schema is deployed. Transfer timing depends on file size, network conditions and operating system scheduling. A 100 MiB attachment was verified by exporting from iPhone and comparing its SHA256 with the original Mac file.

Encrypted backups use a separate password selected at export. Import merges additions and updates while retaining items unique to the current device. Older JSON backups remain supported. New streaming backups use the .shiye extension.

Privacy policy is accessible in System Settings > Privacy policy. There is no advertising or third-party behavioral analytics SDK.

Global Search searches groups, websites, bookmarks, note text and file details. Open it from the sidebar. AI organization is not included in this version.
