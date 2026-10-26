import 'dart:io';

import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Saves generated images to the device gallery.
class GallerySaveService {
  static const MethodChannel _channel = MethodChannel(
    'com.mossapps.flick/storage',
  );

  Future<String> saveImage({
    required Uint8List bytes,
    required String fileName,
    String albumName = 'Lokal',
    bool retryOnPermissionRequest = true,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      throw const GallerySaveException(
        'Saving images is not supported on this platform.',
      );
    }

    try {
      final savedUri = await _channel.invokeMethod<String>(
        'saveImageToGallery',
        {'bytes': bytes, 'fileName': fileName, 'albumName': albumName},
      );

      if (savedUri == null || savedUri.isEmpty) {
        throw const GallerySaveException(
          'Android did not return a gallery path for the saved image.',
        );
      }

      return savedUri;
    } on PlatformException catch (error) {
      if (error.code == 'STORAGE_PERMISSION_REQUIRED' &&
          retryOnPermissionRequest) {
        final status = await Permission.storage.request();
        if (status.isGranted) {
          return saveImage(
            bytes: bytes,
            fileName: fileName,
            albumName: albumName,
            retryOnPermissionRequest: false,
          );
        }

        throw const GallerySaveException(
          'Storage permission is required to save images on this Android version.',
        );
      }

      throw GallerySaveException(
        error.message ?? 'Failed to save the image to your gallery.',
      );
    }
  }
}

class GallerySaveException implements Exception {
  final String message;

  const GallerySaveException(this.message);

  @override
  String toString() => 'GallerySaveException: $message';
}
