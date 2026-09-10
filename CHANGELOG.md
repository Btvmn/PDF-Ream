# Changelog

## 1.0

First public release.

- **Split** a PDF into one file per page, **merge** several PDFs into one, or **compress** each
  file to a size limit you set (0.1–2000 MB; per page for Split, per file for Merge and Compress).
- Lossless first: anything already under the limit is copied untouched. Only what overshoots is
  re-rendered as JPEG, at the highest of 15 quality steps whose real output fits.
- Merge and Compress keep bookmarks and internal links pointing at the right pages; Compress also
  keeps the document title, author, subject and keywords.
- Page rotation, crop boxes and annotations survive; pages that are not re-rendered stay vector,
  with selectable text.
- Files dropped on the window, the Dock icon or opened from Finder only join a list; the action
  button asks where to save and processes the whole list. Files that fail stay in the list for
  another try.
- Universal app (Apple silicon and Intel), macOS 13 or later, no third-party dependencies,
  no network access.
