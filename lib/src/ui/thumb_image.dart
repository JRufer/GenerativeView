import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../core/models.dart';
import '../core/thumb_cache.dart';
import '../theme.dart';

/// Paints an item's thumbnail, requesting it from the core if needed and
/// withdrawing the request if the widget goes away first.
class ThumbImage extends StatefulWidget {
  const ThumbImage({
    super.key,
    required this.cache,
    required this.item,
    required this.tier,
    this.fit = BoxFit.cover,
    this.showPlaceholderIcon = true,
  });

  final ThumbCache cache;
  final MediaItem item;
  final int tier;
  final BoxFit fit;
  final bool showPlaceholderIcon;

  @override
  State<ThumbImage> createState() => _ThumbImageState();
}

class _ThumbImageState extends State<ThumbImage> {
  ui.Image? _image;
  ThumbRequest? _request;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(ThumbImage old) {
    super.didUpdateWidget(old);
    final sameFile = old.item.version == widget.item.version;
    if (sameFile && old.tier == widget.tier) return;
    _request?.cancel();
    _request = null;
    if (!sameFile) {
      _image?.dispose();
      _image = null;
    }
    _resolve();
  }

  void _resolve() {
    final cache = widget.cache;
    final exact = cache.peek(widget.item, widget.tier, exact: true);
    if (exact != null) {
      _image?.dispose();
      _image = exact;
      _failed = false;
      return;
    }
    // Show whatever tier we already have while the right one loads.
    _image ??= cache.peek(widget.item, widget.tier);
    if (cache.hasFailed(widget.item, widget.tier)) {
      _failed = true;
      return;
    }
    _failed = false;
    _request = cache.load(widget.item, widget.tier, _onImage);
  }

  void _onImage(ui.Image? image) {
    _request = null;
    if (!mounted) {
      image?.dispose();
      return;
    }
    setState(() {
      if (image == null) {
        _failed = _image == null;
      } else {
        _image?.dispose();
        _image = image;
        _failed = false;
      }
    });
  }

  @override
  void dispose() {
    _request?.cancel();
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image != null) {
      return RawImage(image: image, fit: widget.fit, filterQuality: FilterQuality.medium);
    }
    if (!widget.showPlaceholderIcon) return const SizedBox.expand();
    if (_failed) {
      return Center(
        child: Icon(
          widget.item.isVideo ? Icons.movie_outlined : Icons.broken_image_outlined,
          color: Palette.faint,
          size: 22,
        ),
      );
    }
    return const SizedBox.expand();
  }
}
