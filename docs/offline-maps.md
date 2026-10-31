# Offline base map areas

The base map always comes from the platform (`/infragis/map/config`, set by the master in the App):
the own PMTiles archive (`pmtiles`) or a MapLibre style (`style`). The app has no public fallback of
its own. Offline areas copy the tiles of that base map into the encrypted tenant database.

- **Download** (map screen, download button): the visible area, from three zoom levels above the
  current one up to the source maximum (at most 15; higher zooms overzoom). The dialog shows the tile
  count, the estimated size and the validity before anything is downloaded; an area above
  6000 tiles asks to zoom in. Progress is shown and the download can be cancelled.
- **Storage**: `map_package` (box, zooms, tiles, bytes, complete, created and valid-until) and
  `map_tile` (source, z, x, y, bytes; absent tiles kept as empty rows) in the encrypted database,
  never in the queues. The style JSON, TileJSON and sprites are kept in `map_resource`, and the last
  map configuration in `meta`, so the map opens offline once it was opened online.
- **Reading**: every vector source of the style is wrapped (`OfflineTileProvider`): a downloaded tile
  comes from the database, anything else from the network. Offline before the PMTiles archive could
  open, only the downloaded tiles are served.
- **Validity**: an area is current for 30 days; after that it is marked outdated and asks to be
  downloaded again, but keeps working.
- **Interrupted download**: what was copied stays as an incomplete area; download it again.
- **Removal** (Sync tab › Offline maps): a sync is attempted first, then only the area and its tiles
  are deleted. Queued assets, photos and work order actions live in other tables and always stay.
- A remote wipe (access removed) deletes the areas and the style copy with the rest of the tenant.
