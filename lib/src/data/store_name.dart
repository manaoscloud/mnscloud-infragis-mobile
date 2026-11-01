/// File of the encrypted copy of a tenant, or of one InfraGIS account of the tenant. The
/// tenant-wide name is the one of the versions without accounts.
String storeFileName(String environmentUuid, String? accountUuid) =>
    accountUuid == null ? 'infragis-$environmentUuid.db' : 'infragis-$environmentUuid-$accountUuid.db';
