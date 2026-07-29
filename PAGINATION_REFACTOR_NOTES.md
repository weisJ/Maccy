# Unlimited History Pagination Refactor

This file is a durable engineering decision log for the history pagination
work. It records the requirements, architecture, tradeoffs, fixes, validation,
commit organization, and remaining handoff work as of 2026-07-26.

## Requirements consolidated from review

- Keep the standard and unlimited history presentation consistent wherever
  modifiers can genuinely be shared.
- Apply top and bottom scroll-content padding inside the custom AppKit-backed
  scroll implementation.
- Explicitly support scroll-indicator insets in the custom scroll
  implementation; do not assume SwiftUI `contentMargins` reaches through an
  `NSViewRepresentable`.
- Paginate only unpinned items. Pinned items form a small, resident section
  before or after the unpinned section.
- Support `MultipleSelectionListView` in unlimited history.
- Preserve selection appearance and navigation across page boundaries by
  giving each page the preceding and following item as boundary context.
- Allow Shift-Up/Down selection to cross page boundaries.
- Do not support Select All.
- In unlimited history, do not support extending a selection directly to the
  first or last item, regardless of any former feature flag.
- Ordinary navigation to the first or last item must remain supported in
  unlimited history.
- Pinning and unpinning must repack/backfill retained pages immediately,
  without holes or a loading-state replacement.
- Search must filter globally before slicing into pages so every non-final
  page remains packed.
- Selection-only changes must not invalidate the collection layout.
- `ListItemView` must remain independent of `HistoryItemDecorator`; hover
  selection uses the existing `selectionId`.
- Do not run UI tests.
- Replace the previous WIP commit with reviewed semantic commits, starting
  with minimum item-height handling, then pinned/unpinned separation, then
  pagination/unlimited-history work.

## Git recovery and semantic history

The former WIP commit was:

- `1e9df40a add new layout`

Its changes were preserved, while the commit itself was removed from the
working branch by resetting to its parent. A safety branch and stash were
created before reorganizing:

- Safety branch: `codex-unlimited2-before-semantic-rewrite`
- Preserved combined worktree: `stash@{0}: pre-semantic-rewrite-working-copy`

The current semantic commits are:

1. `4cf784da Fix minimum list item height`
2. `860d91d4 Separate pinned and unpinned history`
3. `0b41db0c Add packed history page source`

Planned remaining commits:

4. Make history queries and navigation pagination-aware.
5. Render history with recycled, multi-selectable pages.
6. Expose unlimited-history policy and settings.

The exact split may be adjusted to keep every intermediate commit compiling,
but the ordering above is the intended semantic progression.

## Core architecture

### Pinned and unpinned sections

`HistoryItems` presents pinned and unpinned items as one logical ordered
collection. It owns section transitions and display ordering, based on the pin
position setting. Neither section needs to fake a combined array.

Pinned items remain resident and are rendered outside the recycler. Only the
unpinned query is paginated.

### One source type for limited and unlimited history

`PagedHistoryItems` is used for both modes:

- `pageSize == nil`: one fully resident page for limited history.
- finite `pageSize`: demand-loaded pages for unlimited history.

This avoids separate limited/unlimited implementations in `History`,
`HistoryItems`, and the navigation manager. Whole-history selection-extension
capability is derived from `pageSize == nil`; it is not an independently
configurable boolean.

### Immutable queries

`HistoryDataProvider.Query` captures:

- search text;
- sort mode and descriptors;
- page size;
- pinned presentation;
- unpinned count and exact page-layout metadata;
- lazy page loading;
- persistent-model-ID-to-index lookup.

A replacement query is staged and loaded before its accessors are installed in
`PagedHistoryItems`. Retained page identities are preserved across normal
refreshes so hosted SwiftUI page roots do not need to be recreated.

### Packed pages and search

Search is applied to the complete sorted candidate set before the unpinned
results are sliced. Therefore search pages are packed to `pageSize` except for
the final page. Pinned search results remain in the separate pinned section.

This deliberately permits search to materialize its result set: global search
already needs to inspect the complete history. Normal empty-search scrolling
does not materialize all decorators.

### Boundary context

Every page request includes a one-item halo when available:

- the final item before the page;
- the first item after the page.

`PagedHistoryPage` exposes these as `previousItem` and `nextItem`.
`MultipleSelectionListView` accepts them as `itemBeforeFirst` and
`itemAfterLast`. This keeps connected multi-selection styling correct between
recycled page roots.

### Page retention

Visible hosted pages acquire leases. Unleased pages use a small LRU cache.
Selection objects may keep decorators alive after a page is evicted; the page
source remembers their global indices weakly so navigation can resolve them
without retaining every page.

## Pin/unpin mutation design

### Required behavior

After a pin mutation, every retained page is re-fetched from the final sorted
and filtered storage state in one synchronous publication. This naturally:

- removes newly pinned items;
- inserts newly unpinned items at their sorted positions;
- pulls following items forward to fill holes;
- pushes overflow into following pages;
- updates previous/next boundary rows;
- adds or removes the final page when needed.

No retained page is temporarily published with a hole, and no loading view is
shown.

### Avoiding a full history scan

The first implementation rebuilt layout summaries by fetching every unpinned
model after every pin/unpin. Although page objects were preserved, that was
still unnecessary O(total history) work.

The revised empty-search paged path stores a compact
`StorageLayoutIndex`. Each page uses a `UInt64` bitset whose bits identify
image-height rows. With the current page size of 20, this is compact while
retaining the exact row-kind data needed when a removal or insertion shifts
rows through subsequent page boundaries.

For a pin/unpin batch:

1. Capture old indices and image-row kinds for unpinned items being pinned.
2. Save the storage mutation.
3. Batch-resolve the final sorted indices of surviving newly unpinned items.
4. Apply removals in descending old-index order.
5. Apply insertions in ascending final-index order.
6. Validate the resulting count against storage.
7. Build the new query with the patched exact layout summaries.
8. Atomically reload every retained page plus its boundary rows.

The metadata patch is O(affected pages), rather than fetching every history
item and relationship. It never publishes approximate heights.

The provider falls back to a complete query rebuild when any safety condition
is not met, including:

- active search;
- changed sort configuration;
- changed page size or mode;
- a missing/stale old location;
- a missing final insertion index;
- row-kind validation failure;
- an unexpected final item count;
- retention deleting additional existing rows.

Limited history uses one resident page and has at most the configured bounded
size, so falling back there is acceptable.

### Retention

Retention protection for newly unpinned items is a preference, not permission
to exceed the configured limit.

The provider now:

- obtains the unpinned count first;
- fetches only the oldest tail large enough to include the overflow and all
  protected candidates;
- removes oldest unprotected rows first;
- removes protected rows only if required to enforce the limit exactly.

Only surviving newly unpinned items are remembered and considered for the
post-mutation scroll target.

## Navigation and selection

Navigation methods operate on `LocatedHistoryItem`, which contains:

- the decorator;
- its pinned/unpinned section and section-local index;
- the history-order revision that produced the location.

Relative operations verify the revision before and after asynchronous page
loads. A stale operation fails rather than applying an index to a changed
query.

The navigation manager serializes keyboard navigation operations and cancels
or ignores stale generations. Persistent model IDs are used for recycler scroll
requests so an unloaded destination can be located without a SwiftUI view ID.
Pinned destinations deliberately produce no unpinned recycler request.

Selection updates only touch decorators entering or leaving the selection, and
only update `selectionIndex` when its value changes. They do not mutate page
layout metadata or source layout revisions.

### Shortcut policy

The distinction is:

- Shift-Up/Down: extend by one item and cross page boundaries.
- Shift-Command/Option-Up/Down: extend directly to the first/last item; ignored
  for paged unlimited history.
- Command/Option-Up/Down and Page Up/Down: ordinary move to first/last; always
  supported, including unlimited history.

`KeyChord` classifies the shortcut without consulting global history state.
`KeyHandlingView` applies the boundary-extension capability, and the navigation
manager repeats the guard defensively.

The former always-false multi-selection feature switch is being removed now
that multi-selection is supported.

Select All has been removed. The letter `a` is consequently available as a pin
shortcut.

## Recycler and layout

The history-specific AppKit implementation is named
`PagedHistoryScrollView`.

It uses:

- `NSScrollView`;
- a flipped `NSCollectionView`;
- one reusable `NSCollectionViewItem` per history page;
- `NSHostingView` for the page’s SwiftUI content;
- a custom prefix-sum collection layout built from exact page heights.

The collection item class is explicitly registered after installing the
collection layout. This fixes the launch crash where AppKit attempted to load a
nonexistent nib named `PagedHistoryScrollView.HostingPageItem` (the earlier
name in the fault was `RecyclingScrollView.HostingPageItem`).

Every hosted page receives the required SwiftUI environment values explicitly,
which fixes hover selection working only on the first page.

### Exact heights

`ListItemMetrics.minimumHeight(showsApplicationIcon:)` is the single minimum
height calculation.

History rows have two exact scalar heights:

- `regularItemHeight`;
- `imageItemHeight`.

Each `HistoryPageLayoutSummary` stores total row count and image-row count. Its
height is the exact sum of regular and image rows. The host root is constrained
to that exact page height, preventing overlap and preventing the final row from
being clipped.

Changing selection does not change either height and therefore does not
invalidate the collection layout.

### Padding and scroll indicators

Top and bottom content padding are represented as explicit collection-layout
content insets, not modifiers placed inside a list that the recycler no longer
owns.

Scroll-indicator margins are represented separately as explicit
`NSScrollView.scrollerInsets`, including:

- current top padding;
- current bottom padding;
- the former 10-point leading indicator margin.

`automaticallyAdjustsContentInsets` is disabled so AppKit does not overwrite
the explicit values. This is the AppKit equivalent path; SwiftUI
`contentMargins(..., for: .scrollIndicators)` cannot be assumed to modify the
wrapped `NSScrollView`.

Pinned sections are measured independently above or below the recycler. A
change in either measured height marks the popup for resizing.

## Runtime fixes

### Immediate AppKit crash

The attached fault reported:

`NSInternalInconsistencyException: could not load nib
'RecyclingScrollView.HostingPageItem'`

Cause: the collection view item class was not explicitly registered before
dequeue. AppKit treated the reuse identifier as a nib name.

Fix:

- install the collection layout;
- register `HostingPageItem.self as AnyClass`;
- then attach data source/delegate and dequeue normally.

A Debug app build and launch smoke check kept the process alive without the
fault.

### Shift-Arrow did nothing

Cause: multi-selection was still gated by an always-false
`multiSelectionEnabled` feature switch.

Fix: remove the dead feature switch and make Shift-Up/Down map directly to
one-item selection extension.

### Cold move-to-last

Audit found that `UnpinnedHistoryItems.last()` used `count - 1` before a lazy
paged source had loaded its count. A cold `last()` could therefore return nil.

Fix:

- make `first()` and `last()` protocol requirements with defaults;
- let `PagedHistoryItems.last()` initialize the query first, then load the
  page containing `count - 1`;
- run the endpoint test with `last()` before `first()`.

## Test coverage

Focused non-UI coverage includes:

- packed page ranges, global indices, and boundary rows;
- relative navigation across an evicted page boundary;
- retained-page backfill after removals and insertions;
- page-count changes;
- exact image/regular page-height summaries;
- decorator identity across page eviction and pin ownership;
- stale history-location rejection;
- first/last endpoint navigation on a cold paged source while direct
  whole-history range extension is unavailable;
- pinned scroll requests being rejected by the unpinned recycler;
- compact layout-index removal/insertion propagation across page boundaries;
- stale row-kind metadata falling back instead of publishing incorrect
  heights;
- boundary shortcut classification.

Latest completed focused result:

- `PagedHistoryItemsTests`: 13 tests, 0 failures.

Earlier completed focused result:

- `HistoryItemsTests`: 10 tests, 0 failures before the final cold-last and
  shortcut additions; it must be rerun after final integration.

Build status:

- Debug `Maccy` app build succeeded with code signing disabled before the final
  mutation-index and cold-last refinements.
- A final Debug build remains to be run after all edits settle.

No UI tests have been run.

`HistoryTests` is skipped by `Maccy.xctestplan`, so critical paging behavior is
kept in the enabled pure page/history-item test suites.

## Remaining work before handoff

1. Finish the final mutation-path review and ensure no shared-worktree edits
   were lost.
2. Run `git diff --check`, parse/lint checks, a final Debug app build, and the
   focused `HistoryItemsTests` plus `PagedHistoryItemsTests` only.
3. Do not run `MaccyUITests`.
4. Review the final diff for naming and dead compatibility APIs.
5. Create the remaining semantic commits.
6. Verify the staged PBX diff contains only the new
   `PagedHistoryScrollView.swift` references.
7. Leave unrelated user changes unstaged.

## Working-tree hazards

The PBX file also contains unrelated user changes:

- removal of a stale `Data+Encoding.swift` reference;
- two `DEVELOPMENT_TEAM` changes.

These must not be included in the pagination commits.

`default.profraw` is an untracked, zero-byte generated profiling artifact and
must not be staged.

Do not use blanket `git add -A`.

