import 'package:flutter/material.dart';
import 'package:ping_files/theme/colors2.dart';

class AppPullToRefresh extends StatelessWidget {
  final Widget child;
  final Future<void> Function() onRefresh;
  final double displacement;
  final Color? color;
  final Color? backgroundColor;

  const AppPullToRefresh({
    super.key,
    required this.child,
    required this.onRefresh,
    this.displacement = 56,
    this.color,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: onRefresh,
      displacement: displacement,
      color: color ?? AppColors.brandGreen,
      backgroundColor: backgroundColor ?? Colors.white,
      child: _RefreshScrollableSurface(
        child: child,
      ),
    );
  }
}

class _RefreshScrollableSurface extends StatelessWidget {
  final Widget child;

  const _RefreshScrollableSurface({
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    if (child is NestedScrollView) {
      final nested = child as NestedScrollView;

      return NestedScrollView(
        key: nested.key,
        controller: nested.controller,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        scrollBehavior: nested.scrollBehavior,
        dragStartBehavior: nested.dragStartBehavior,
        floatHeaderSlivers: nested.floatHeaderSlivers,
        clipBehavior: nested.clipBehavior,
        restorationId: nested.restorationId,
        headerSliverBuilder: nested.headerSliverBuilder,
        body: nested.body,
      );
    }

    if (child is CustomScrollView) {
      final scroll = child as CustomScrollView;

      return CustomScrollView(
        key: scroll.key,
        scrollDirection: scroll.scrollDirection,
        reverse: scroll.reverse,
        controller: scroll.controller,
        primary: scroll.primary,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        shrinkWrap: scroll.shrinkWrap,
        center: scroll.center,
        anchor: scroll.anchor,
        cacheExtent: scroll.cacheExtent,
        semanticChildCount: scroll.semanticChildCount,
        dragStartBehavior: scroll.dragStartBehavior,
        slivers: scroll.slivers,
        clipBehavior: scroll.clipBehavior,
        restorationId: scroll.restorationId,
      );
    }

    if (child is ListView) {
      final list = child as ListView;

      return ListView.builder(
        key: list.key,
        scrollDirection: list.scrollDirection,
        reverse: list.reverse,
        controller: list.controller,
        primary: list.primary,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        shrinkWrap: list.shrinkWrap,
        padding: list.padding,
        itemCount: list.childrenDelegate.estimatedChildCount,
        itemBuilder: (context, index) {
          return (list.childrenDelegate as SliverChildBuilderDelegate)
              .builder(context, index);
        },
      );
    }

    if (child is SingleChildScrollView) {
      final scroll = child as SingleChildScrollView;

      return SingleChildScrollView(
        key: scroll.key,
        scrollDirection: scroll.scrollDirection,
        reverse: scroll.reverse,
        padding: scroll.padding,
        primary: scroll.primary,
        physics: const AlwaysScrollableScrollPhysics(
          parent: BouncingScrollPhysics(),
        ),
        controller: scroll.controller,
        clipBehavior: scroll.clipBehavior,
        dragStartBehavior: scroll.dragStartBehavior,
        restorationId: scroll.restorationId,
        keyboardDismissBehavior: scroll.keyboardDismissBehavior,
        child: scroll.child,
      );
    }

    return SingleChildScrollView(
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minHeight: MediaQuery.of(context).size.height * 0.78,
        ),
        child: child,
      ),
    );
  }
}