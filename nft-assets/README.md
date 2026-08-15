# THRINWULF 1,652 release workspace

Final media is not committed to Git. Prepare `final-manifest.csv` with exactly 1,652 rows and these columns:

`asset_id,rarity,image_uri,name,description`

Required fixed counts: Common 826, Uncommon 413, Rare 248, Epic 99, Legendary 49, Mythic 16, Unicorn 1. Every `image_uri` must be a unique `ipfs://` URI already pinned through 4EVERLAND. Mystery and Pre-Reveal are two separate shared metadata files and are not token IDs.

After the collection contract address is known, keep `RARITY_SEED` offline and run `generate-final-metadata.js`. The script assigns categorized art to token IDs using the same committed offset formula as the contract, then `validate-1652-release.js` creates the SHA-256 manifest.

`drive-collection.csv` is the canonical pre-IPFS registry for the 1,652 reveal assets.
`drive-inventory.json` records the exact rarity architecture, shared lifecycle assets
and designated one-of-one. Its `image_uri` values remain empty until 4EVERLAND CID
verification completes; final metadata must never use a Google Drive URL.
