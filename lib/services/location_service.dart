import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';

class LocationService {
  // Get current position with high accuracy
  static Future<Position?> getCurrentPosition() async {
    bool serviceEnabled;
    LocationPermission permission;

    // Test if location services are enabled.
    serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      // Location services are not enabled
      return null;
    }

    permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        // Permissions are denied
        return null;
      }
    }
    
    if (permission == LocationPermission.deniedForever) {
      // Permissions are denied forever
      return null;
    } 

    // When we reach here, permissions are granted and we can get the position
    try {
      return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
    } catch (e) {
      print('Error getting current position: $e');
      return null;
    }
  }

  // Get address from coordinates
  static Future<String> getAddressFromCoordinates(double latitude, double longitude) async {
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(latitude, longitude);
      
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        
        // Create a detailed address with house number, street name, district, and city
        String detailedAddress = '';
        
        // Add house number and street name
        if (place.name != null && place.name!.isNotEmpty) {
          detailedAddress += place.name!;
        }
        
        if (place.street != null && place.street!.isNotEmpty) {
          if (detailedAddress.isNotEmpty) detailedAddress += ', ';
          detailedAddress += place.street!;
        }
        
        // Add subLocality (ward/neighborhood)
        if (place.subLocality != null && place.subLocality!.isNotEmpty) {
          if (detailedAddress.isNotEmpty) detailedAddress += ', ';
          detailedAddress += place.subLocality!;
        }
        
        // Add locality (district)
        if (place.locality != null && place.locality!.isNotEmpty) {
          if (detailedAddress.isNotEmpty) detailedAddress += ', ';
          detailedAddress += place.locality!;
        }
        
        // Add administrativeArea (city/province)
        if (place.administrativeArea != null && place.administrativeArea!.isNotEmpty) {
          if (detailedAddress.isNotEmpty) detailedAddress += ', ';
          detailedAddress += place.administrativeArea!;
        }
        
        // Add country
        if (place.country != null && place.country!.isNotEmpty) {
          if (detailedAddress.isNotEmpty) detailedAddress += ', ';
          detailedAddress += place.country!;
        }
        
        return detailedAddress.isNotEmpty ? detailedAddress : 'Unknown location';
      }
      
      return 'Unknown location';
    } catch (e) {
      print('Error getting address: $e');
      return 'Unknown location';
    }
  }
  
  // Get detailed address components from coordinates
  static Future<Map<String, String>> getDetailedAddressComponents(double latitude, double longitude) async {
    Map<String, String> addressComponents = {
      'houseNumber': '',
      'street': '',
      'ward': '',
      'district': '',
      'city': '',
      'country': '',
      'fullAddress': '',
    };
    
    try {
      List<Placemark> placemarks = await placemarkFromCoordinates(latitude, longitude);
      
      if (placemarks.isNotEmpty) {
        Placemark place = placemarks[0];
        
        // Extract house number from name or street if available
        addressComponents['houseNumber'] = place.name ?? '';
        addressComponents['street'] = place.street ?? '';
        addressComponents['ward'] = place.subLocality ?? '';
        addressComponents['district'] = place.locality ?? '';
        addressComponents['city'] = place.administrativeArea ?? '';
        addressComponents['country'] = place.country ?? '';
        
        // Get full address
        addressComponents['fullAddress'] = await getAddressFromCoordinates(latitude, longitude);
      }
    } catch (e) {
      print('Error getting detailed address components: $e');
    }
    
    return addressComponents;
  }
}
