import 'package:auto_route/auto_route.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/build_context_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/utils/bytes_units.dart';
import 'package:path/path.dart' as path;

@RoutePage()
class DriftUploadDetailPage extends ConsumerStatefulWidget {
  const DriftUploadDetailPage({super.key});

  @override
  ConsumerState<DriftUploadDetailPage> createState() => _DriftUploadDetailPageState();
}

class _DriftUploadDetailPageState extends ConsumerState<DriftUploadDetailPage> {
  static const double _uploadCardContentHeight = 82;

  @override
  Widget build(BuildContext context) {
    final uploadItems = ref.watch(driftBackupProvider.select((state) => state.uploadItems));
    final iCloudProgress = ref.watch(driftBackupProvider.select((state) => state.iCloudDownloadProgress));

    final uploadingItems = uploadItems.values
        .where(
          (item) =>
              item.isFailed != true &&
              (item.progress < 1.0 || (item.compressionExpected && item.preparationProgress < 1.0)),
        )
        .toList();
    final failedItems = uploadItems.values.where((item) => item.isFailed == true).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text("upload_details".t(context: context)),
        backgroundColor: context.colorScheme.surface,
        elevation: 0,
        scrolledUnderElevation: 1,
      ),
      body: _buildTwoSectionLayout(context, uploadingItems, failedItems, iCloudProgress),
    );
  }

  Widget _buildTwoSectionLayout(
    BuildContext context,
    List<DriftUploadStatus> uploadingItems,
    List<DriftUploadStatus> failedItems,
    Map<String, double> iCloudProgress,
  ) {
    return CustomScrollView(
      slivers: [
        // iCloud Downloads Section
        if (iCloudProgress.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              context,
              title: "Downloading from iCloud",
              count: iCloudProgress.length,
              color: context.colorScheme.tertiary,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final entry = iCloudProgress.entries.elementAt(index);
                return Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildICloudDownloadCard(context, entry.key, entry.value),
                );
              }, childCount: iCloudProgress.length),
            ),
          ),
        ],

        // Uploading Section
        SliverToBoxAdapter(
          child: _buildSectionHeader(
            context,
            title: "uploading".t(context: context),
            count: uploadingItems.length,
            color: context.colorScheme.primary,
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          sliver: uploadingItems.isEmpty
              ? SliverToBoxAdapter(child: _buildEmptyUploadState(context))
              : SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (context, index) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: _buildCurrentUploadCard(context, uploadingItems[index]),
                    ),
                    childCount: uploadingItems.length,
                  ),
                ),
        ),

        // Errors Section
        if (failedItems.isNotEmpty) ...[
          SliverToBoxAdapter(
            child: _buildSectionHeader(
              context,
              title: "errors_text".t(context: context),
              count: failedItems.length,
              color: context.colorScheme.error,
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                final item = failedItems[index];
                return Padding(padding: const EdgeInsets.only(bottom: 8), child: _buildErrorCard(context, item));
              }, childCount: failedItems.length),
            ),
          ),
        ],

        // Bottom padding
        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, {required String title, int? count, required Color color}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: context.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: color),
          ),
          const SizedBox(width: 8),
          count != null
              ? Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.15),
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                  child: Text(
                    count.toString(),
                    style: context.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.bold, color: color),
                  ),
                )
              : const SizedBox.shrink(),
        ],
      ),
    );
  }

  Widget _buildICloudDownloadCard(BuildContext context, String assetId, double progress) {
    final double progressPercentage = (progress * 100).clamp(0, 100);

    return Card(
      elevation: 0,
      color: context.colorScheme.tertiaryContainer.withValues(alpha: 0.5),
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: context.colorScheme.tertiary.withValues(alpha: 0.3), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.colorScheme.tertiary.withValues(alpha: 0.2),
                borderRadius: const BorderRadius.all(Radius.circular(8)),
              ),
              child: Icon(Icons.cloud_download_rounded, size: 24, color: context.colorScheme.tertiary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "downloading_from_icloud".t(context: context),
                    style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    assetId,
                    style: context.textTheme.bodySmall?.copyWith(
                      color: context.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: const BorderRadius.all(Radius.circular(4)),
                    child: LinearProgressIndicator(
                      value: progress,
                      backgroundColor: context.colorScheme.tertiary.withValues(alpha: 0.2),
                      valueColor: AlwaysStoppedAnimation(context.colorScheme.tertiary),
                      minHeight: 4,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 48,
              child: Text(
                "${progressPercentage.toStringAsFixed(0)}%",
                textAlign: TextAlign.right,
                style: context.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: context.colorScheme.tertiary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCurrentUploadCard(BuildContext context, DriftUploadStatus item) {
    final isUploading = item.progress < 0.999;
    final activeProgress = isUploading ? item.progress : item.preparationProgress;
    final activeColor = isUploading ? context.colorScheme.primary : context.colorScheme.tertiary;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        side: BorderSide(color: context.colorScheme.outline.withValues(alpha: 0.14), width: 1),
      ),
      child: InkWell(
        onTap: () => _showFileDetailDialog(context, item),
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        child: SizedBox(
          height: _uploadCardContentHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _CurrentUploadThumbnail(taskId: item.taskId),
                const SizedBox(width: 9),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              path.basename(item.filename),
                              style: context.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${(activeProgress.clamp(0.0, 1.0) * 100).round()}%',
                            style: context.textTheme.labelSmall?.copyWith(
                              color: activeColor,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      _buildCompactSizeSummary(context, item),
                      const SizedBox(height: 6),
                      _buildCompactStageProgress(
                        context,
                        label: "backup_upload_stage".t(context: context),
                        detail: item.networkSpeedAsString,
                        progress: item.progress,
                        color: context.colorScheme.primary,
                      ),
                      if (item.compressionExpected && !isUploading) ...[
                        const SizedBox(height: 4),
                        _buildCompactStageProgress(
                          context,
                          label: 'Cloud compression',
                          progress: item.preparationProgress,
                          color: context.colorScheme.tertiary,
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCompactSizeSummary(BuildContext context, DriftUploadStatus item) {
    final hasPreparedSize = item.fileSize > 0;
    final originalSize = formatHumanReadableBytes(item.originalFileSize, 1);
    final compressedSize = hasPreparedSize
        ? formatHumanReadableBytes(item.fileSize, 1)
        : item.progress < 0.999
        ? 'waiting for upload'
        : 'compressing on server';
    final savingsPercent = calculateStorageSavingsPercent(item.originalFileSize, item.fileSize);
    final savings = savingsPercent == null ? '' : ' · ${savingsPercent > 0 ? '−$savingsPercent%' : '0%'}';
    return Text(
      '$originalSize → $compressedSize$savings',
      style: context.textTheme.labelSmall?.copyWith(
        color: context.colorScheme.onSurface.withValues(alpha: 0.68),
        fontWeight: FontWeight.w600,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildCompactStageProgress(
    BuildContext context, {
    required String label,
    required double progress,
    required Color color,
    String detail = '',
  }) {
    final normalizedProgress = progress.clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 82,
          child: Text(
            detail.isEmpty ? label : '$label · $detail',
            style: context.textTheme.labelSmall?.copyWith(fontSize: 9.5, fontWeight: FontWeight.w600),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: ClipRRect(
            borderRadius: const BorderRadius.all(Radius.circular(99)),
            child: LinearProgressIndicator(
              value: normalizedProgress,
              backgroundColor: color.withValues(alpha: 0.14),
              valueColor: AlwaysStoppedAnimation(color),
              minHeight: 4,
            ),
          ),
        ),
        const SizedBox(width: 6),
        SizedBox(
          width: 28,
          child: Text(
            '${(normalizedProgress * 100).round()}%',
            textAlign: TextAlign.right,
            style: context.textTheme.labelSmall?.copyWith(fontSize: 9.5, color: color, fontWeight: FontWeight.w800),
          ),
        ),
      ],
    );
  }

  Widget _buildErrorCard(BuildContext context, DriftUploadStatus item) {
    return Card(
      elevation: 0,
      color: context.colorScheme.errorContainer,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        side: BorderSide(color: context.colorScheme.error.withValues(alpha: 0.3), width: 1),
      ),
      child: InkWell(
        onTap: () => _showFileDetailDialog(context, item),
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              _CurrentUploadThumbnail(taskId: item.taskId),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      path.basename(item.filename),
                      style: context.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      item.error ?? "unable_to_upload_file".t(context: context),
                      style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.error),
                      maxLines: 4,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Icon(Icons.error_rounded, color: context.colorScheme.error, size: 28),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyUploadState(BuildContext context) {
    return Container(
      height: _uploadCardContentHeight,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        borderRadius: const BorderRadius.all(Radius.circular(10)),
        border: Border.all(color: context.colorScheme.outline.withValues(alpha: 0.12)),
      ),
      child: Text(
        'No active uploads',
        style: context.textTheme.bodySmall?.copyWith(color: context.colorScheme.onSurfaceVariant),
      ),
    );
  }

  Future<void> _showFileDetailDialog(BuildContext context, DriftUploadStatus item) {
    return showDialog(
      context: context,
      builder: (context) => FileDetailDialog(uploadStatus: item),
    );
  }
}

class _CurrentUploadThumbnail extends ConsumerWidget {
  final String taskId;
  const _CurrentUploadThumbnail({required this.taskId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return FutureBuilder<LocalAsset?>(
      future: _getAsset(ref),
      builder: (context, snapshot) {
        return SizedBox(
          width: 48,
          height: 48,
          child: Container(
            decoration: BoxDecoration(
              color: context.colorScheme.primary.withValues(alpha: 0.2),
              borderRadius: const BorderRadius.all(Radius.circular(8)),
            ),
            clipBehavior: Clip.antiAlias,
            child: snapshot.data != null
                ? Thumbnail.fromAsset(asset: snapshot.data!, size: const Size(48, 48), fit: BoxFit.cover)
                : Icon(Icons.image, size: 24, color: context.colorScheme.primary),
          ),
        );
      },
    );
  }

  Future<LocalAsset?> _getAsset(WidgetRef ref) async {
    try {
      return await ref.read(localAssetRepository).getById(taskId);
    } catch (e) {
      return null;
    }
  }
}

class FileDetailDialog extends ConsumerWidget {
  final DriftUploadStatus uploadStatus;
  const FileDetailDialog({super.key, required this.uploadStatus});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return AlertDialog(
      insetPadding: const EdgeInsets.all(20),
      backgroundColor: context.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: const BorderRadius.all(Radius.circular(16)),
        side: BorderSide(color: context.colorScheme.outline.withValues(alpha: 0.2), width: 1),
      ),
      title: Row(
        children: [
          Icon(Icons.info_outline, color: context.primaryColor, size: 24),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "details".t(context: context),
              style: context.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: context.primaryColor),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: FutureBuilder<LocalAsset?>(
          future: _getAssetDetails(ref, uploadStatus.taskId),
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const SizedBox(height: 200, child: Center(child: CircularProgressIndicator()));
            }
            final asset = snapshot.data;
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Center(
                    child: ClipRRect(
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: Container(
                        width: 128,
                        height: 128,
                        decoration: BoxDecoration(
                          border: Border.all(color: context.colorScheme.outline.withValues(alpha: 0.2), width: 1),
                          borderRadius: const BorderRadius.all(Radius.circular(12)),
                        ),
                        child: asset != null
                            ? Thumbnail.fromAsset(asset: asset, size: const Size(128, 128), fit: BoxFit.cover)
                            : null,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (asset != null)
                    _buildInfoSection(context, [
                      _buildInfoRow(context, "filename".t(context: context), path.basename(uploadStatus.filename)),
                      _buildInfoRow(context, "local_id".t(context: context), asset.id),
                      _buildInfoRow(
                        context,
                        "backup_original_size".t(context: context),
                        formatHumanReadableBytes(uploadStatus.originalFileSize, 2),
                      ),
                      _buildInfoRow(
                        context,
                        "backup_compressed_size".t(context: context),
                        uploadStatus.fileSize > 0 ? formatHumanReadableBytes(uploadStatus.fileSize, 2) : '—',
                      ),
                      if (asset.width != null) _buildInfoRow(context, "width".t(context: context), "${asset.width}px"),
                      if (asset.height != null)
                        _buildInfoRow(context, "height".t(context: context), "${asset.height}px"),
                      _buildInfoRow(context, "created_at".t(context: context), asset.createdAt.toString()),
                      _buildInfoRow(context, "updated_at".t(context: context), asset.updatedAt.toString()),
                      if (asset.checksum != null)
                        _buildInfoRow(context, "checksum".t(context: context), asset.checksum!),
                    ]),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            "close".t(),
            style: TextStyle(fontWeight: FontWeight.w600, color: context.primaryColor),
          ),
        ),
      ],
    );
  }

  Widget _buildInfoSection(BuildContext context, List<Widget> children) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainer,
        borderRadius: const BorderRadius.all(Radius.circular(12)),
        border: Border.all(color: context.colorScheme.outline.withValues(alpha: 0.1), width: 1),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: children),
    );
  }

  Widget _buildInfoRow(BuildContext context, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              "$label:",
              style: context.textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w500,
                color: context.colorScheme.onSurface.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: context.textTheme.labelMedium, maxLines: 3, overflow: TextOverflow.ellipsis),
          ),
        ],
      ),
    );
  }

  Future<LocalAsset?> _getAssetDetails(WidgetRef ref, String localAssetId) async {
    try {
      return await ref.read(localAssetRepository).getById(localAssetId);
    } catch (e) {
      return null;
    }
  }
}
