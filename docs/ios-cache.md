# iOS Cache

This document is for contributors who work on the native iOS and iPadOS app in
`mobile/ios`. It describes `Cache` in StrideKit: what it keeps, where, how each
entry carries the time it was fetched for the offline banner, and when it is
wiped. `Connectivity`, which says whether the device is online, is described at
the end. The design is section 11 of the
[Phase 1 design](plans/NATIVE-MOBILE-APPS-PHASE-1-DESIGN.md).

## What it keeps

The cache keeps each response as JSON encoded from its StrideKit type, keyed by
the kind and the API's id, with the time it was stored. It is not the API's own
JSON: fields the type does not know are not kept, so a build whose type no
longer decodes a stored response drops it. A `CacheKey` names the response and
the type it decodes to:

| Key | Response | How many |
|---|---|---|
| `.decisions` | `GET /api/me/decisions` | one |
| `.reviewQueue` | `GET /api/me/reviews`, in the server's order | one |
| `.review(taskID:)` | `GET /api/me/reviews/{task_id}` | the last 20 opened (`Cache.openedLimit`) |
| `.reviewFile(taskID:index:filesVersion:)` | `GET /api/me/reviews/{task_id}/files/{index}` | as long as its review is kept |

The other kinds section 11 lists, such as boards, agents,
targets and goals, are added with the screens that show them. Add each to
`CacheKind` with its limit and its store, and a `CacheKey` for it.

- **The limit.** Storing a review drops the least recently fetched reviews past
  the newest 20, never the one just stored, even when the clock has gone back.
  Storing a review again makes it the newest.
- **Files go with their review.** A file can be stored only while its review is
  cached (`CacheError.parentNotCached` otherwise), and it goes when its review
  is evicted. The files version is part of a file's key, so a file read from an
  older list is never shown beside a newer review, and storing a file of one
  files version drops the review's files of the others.
- **One row per response.** The payload and its fetch time are one SwiftData
  row, so a reader sees either the whole old response or the whole new one.

## Reading and storing

```swift
let epoch = await cache.epoch
let list = try await api.listMyDecisions().ok.body.json.data
try await cache.store(list, for: .decisions, since: epoch)

if let cached = try await cache.cached(.decisions) {
    // cached.value, and cached.fetchedAt for OfflineBannerContent
}
```

`cached(_:)` returns nil when nothing is cached, and also when the row was
written by a version of the app that encoded the response differently; that row
is deleted and the response is fetched again. Read `epoch` before asking the API
and pass it to `store`: when the cache was wiped while the answer was on its
way, `store` throws `CacheError.superseded` and keeps nothing, so a sign-out
cannot be undone by a late answer.

`StrideApp.cache` is the app's one cache. Only the app stores and wipes; an
extension such as the widget may only read, and opens a fresh `Cache` for each
read. A wipe deletes the store files, so a `Cache` kept open in another process
would go on reading the deleted files and never see what the app stores after
the next sign-in.

## Where it lives

The cache is in the app group container, under `Cache/`, in two SwiftData
stores, one for each Data Protection class:

| Folder | Protection | Holds |
|---|---|---|
| `Cache/AfterFirstUnlock` | `completeUntilFirstUserAuthentication` | the decisions list, which the widget reads while the phone is locked |
| `Cache/WhileUnlocked` | `complete` | everything else, such as reviews and their diffs with code |

Each folder gets its class when it is made, and the store and its journal files
take it from the folder. `Cache/` is excluded from backups. The install marker
beside it is never touched.

## Versions and damage

The schema is `CacheSchemaV1`, opened through `CacheMigrationPlan`. A change to
the entry adds `CacheSchemaV2` and a stage. When a store cannot be opened, as
after damage or when it comes from a version no stage can bring forward, the
cache deletes that store and starts it again, since everything in it can be
fetched again. A store that is there but cannot be read, as while the phone is
locked, is never reset: the call throws `CacheError.unavailable` and the store is
read again later.

SwiftData's `#Unique`, `#Index` and `deleteAllData()` need iOS 18, and the app
supports iOS 17, so the key is `@Attribute(.unique)` and a wipe deletes the rows
itself.

## Wiping

`wipe()` deletes every row, then the `Cache/` folder, and moves `epoch` on.
`SignInModel` calls it each time the stored sign-in says signed out: on a
sign-out, when the server refuses the device (`AuthStore` clears the pair and
says signed out), and at a launch that starts signed out. A person who signs in
after another therefore starts with an empty cache. A failed wipe is tried again
at the next of these.

## Connectivity

`Connectivity.system.states()` is an `AsyncStream` of `ConnectivityState`,
`.online` or `.offline`, from the system's path monitor. It gives the state now
and then each change, never the same state twice in a row, and keeps only the
newest state for a slow reader. Stopping the loop stops the monitor. Tests pass
their own path source to `Connectivity(source:)`.

While offline a screen shows `OfflineBanner` with the cached response's
`fetchedAt` and disables the actions that need a connection; nothing is queued.

## Testing it

`CacheTests` covers storing and reading with the fetch time, the limits,
files going with their review, wiping, a write that set out before a wipe, a
second reader during writes, a damaged store, a store from another schema
version, a response this version cannot read, a store that cannot be read, the
protection classes and the app group container. `ConnectivityTests` covers the
changes and stopping the source, and `SignInModelTests` checks that a sign-out
wipes the cache.
