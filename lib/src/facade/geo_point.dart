part of '../../winche_database.dart';

/// Facade-level geographic point (latitude, longitude).
///
/// Converts to/from [GeoPointValue] via the converters layer.
class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);

  final double latitude;
  final double longitude;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other.runtimeType == GeoPoint &&
          (other as GeoPoint).latitude == latitude &&
          other.longitude == longitude;

  @override
  int get hashCode => Object.hash(GeoPoint, latitude, longitude);

  @override
  String toString() => 'GeoPoint($latitude, $longitude)';
}
