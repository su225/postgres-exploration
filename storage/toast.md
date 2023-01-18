# Storage class 'plain'
* No compression allowed. Full attribute is stored even breaching "at least 4 per page" rule
* Moving to TOAST is not allowed

# Storage class 'extended'
* Compression is allowed and it can move data to TOAST table
* "at least 4 per page" is allowed.

# Storage class 'external'
* Compression is NOT allowed
* Only moving to TOAST table is allowed.
* Speeds up searching within a range for strings and bytes

# Storage class 'main'
* Compression is allowed
* TOAST table storage is "last-resort only"