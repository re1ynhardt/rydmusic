import 'dart:typed_data';

import 'package:crop_your_image/crop_your_image.dart';
import 'package:flutter/material.dart';

import '../providers/language_provider.dart';
import '../theme/app_theme.dart';

/// Полноэкранный кроппер для аватарки. Берёт сырые байты выбранного
/// изображения, отдаёт обрезанный квадратный PNG через Navigator.pop.
class AvatarCropScreen extends StatefulWidget {
  const AvatarCropScreen({
    super.key,
    required this.imageBytes,
    this.aspectRatio = 1,
    this.withCircleUi = true,
    this.titleOverride,
  });

  final Uint8List imageBytes;
  final double aspectRatio;
  final bool withCircleUi;
  final String? titleOverride;

  @override
  State<AvatarCropScreen> createState() => _AvatarCropScreenState();
}

class _AvatarCropScreenState extends State<AvatarCropScreen> {
  final _controller = CropController();
  bool _cropping = false;

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.titleOverride ?? l10n.cropAvatarTitle),
        leading: IconButton(
          icon: const Icon(Icons.close_rounded),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton(
            onPressed: _cropping ? null : () => _controller.crop(),
            child: _cropping
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  )
                : Text(l10n.done,
                    style: const TextStyle(
                        color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
      body: Crop(
        controller: _controller,
        image: widget.imageBytes,
        aspectRatio: widget.aspectRatio,
        withCircleUi: widget.withCircleUi,
        baseColor: Colors.black,
        maskColor: Colors.black.withOpacity(0.65),
        interactive: true,
        cornerDotBuilder: (size, edgeAlignment) => const SizedBox.shrink(),
        onStatusChanged: (status) {
          setState(() => _cropping = status == CropStatus.cropping);
        },
        onCropped: (image) {
          Navigator.of(context).pop<Uint8List>(image);
        },
      ),
    );
  }
}
