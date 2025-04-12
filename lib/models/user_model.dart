class User {
  final String name;
  final String dob;
  final String cccd;
  final bool faceScanned;
  final String? faceData; // Primary face data (front angle)
  final List<String>? allFaceData; // Store face data from multiple angles
  final DateTime registeredAt;
  final Map<String, String>? addressComponents; // Detailed address components

  User({
    required this.name,
    required this.dob,
    required this.cccd,
    required this.faceScanned,
    this.faceData, // Optional during initialization but will be set during face scan
    this.allFaceData, // Optional list of face data from multiple angles
    required this.registeredAt,
    this.addressComponents, // Optional detailed address components
  });

  // Convert User object to a Map for storing in SharedPreferences
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'dob': dob,
      'cccd': cccd,
      'faceScanned': faceScanned,
      'faceData': faceData,
      'allFaceData': allFaceData,
      'registeredAt': registeredAt.toIso8601String(),
      'addressComponents': addressComponents,
    };
  }

  // Create a User object from a Map retrieved from SharedPreferences
  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      name: json['name'],
      dob: json['dob'],
      cccd: json['cccd'],
      faceScanned: json['faceScanned'],
      faceData: json['faceData'],
      allFaceData: json['allFaceData'] != null 
          ? List<String>.from(json['allFaceData']) 
          : null,
      registeredAt: DateTime.parse(json['registeredAt']),
      addressComponents: json['addressComponents'] != null 
          ? Map<String, String>.from(json['addressComponents']) 
          : null,
    );
  }
}
