import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:ros_tester/costmap_layer.dart';
import 'package:ros_tester/map_geometry.dart';

Map<String, Object?> grid(int w, int h, List<int> data,
    {double res = 0.5, double ox = 0, double oy = 0, String frame = 'odom'}) => {
  'header': {'frame_id': frame},
  'info': {'width': w, 'height': h, 'resolution': res, 'origin': {
    'position': {'x': ox, 'y': oy, 'z': 0.0}, 'orientation': {'x': 0.0, 'y': 0.0, 'z': 0.0, 'w': 1.0}}},
  'data': data,
};

void main() {
  test('the costmap topic is the robot\'s own, found by Nav2\'s names; the map itself is not one', () {
    const grids = 'nav_msgs/msg/OccupancyGrid';
    final topics = {'/map': grids, '/local_costmap/costmap': grids, '/global_costmap/costmap': grids,
      '/robot2/local_costmap/costmap': grids, '/local_costmap/costmap_updates': 'map_msgs/msg/OccupancyGridUpdate',
      '/odom': 'nav_msgs/msg/Odometry'};
    expect(costmapTopicIn(topics, CostmapKind.local), '/local_costmap/costmap');
    expect(costmapTopicIn(topics, CostmapKind.global), '/global_costmap/costmap');
    expect(costmapTopicIn(topics, CostmapKind.local, namespace: '/robot2'), '/robot2/local_costmap/costmap');
    expect(costmapTopicIn(topics, CostmapKind.global, namespace: '/robot2'), isNull,
        reason: 'robot2 has no global costmap of its own');
    expect(costmapTopicIn({'/map': grids}, CostmapKind.local), isNull);
    expect(costmapTopicIn({'/a/local_costmap/costmap': grids, '/b/local_costmap/costmap': grids}, CostmapKind.local),
        isNull, reason: 'two robots and no way to tell which is this one');
  });

  test('a message is read; empty, inconsistent and oversized grids are refused', () {
    final c = Costmap.fromMessage(grid(3, 2, [0, 50, 99, 100, -1, 10], ox: -1, oy: 2))!;
    expect((c.width, c.height, c.resolution, c.frame), (3, 2, 0.5, 'odom'));
    expect((c.origin.x, c.origin.y), (-1, 2));
    expect(Costmap.fromMessage(grid(3, 2, [0, 1])), isNull, reason: 'data does not fill the grid');
    expect(Costmap.fromMessage(grid(0, 0, [])), isNull);
    expect(Costmap.fromMessage({'info': 5}), isNull);
    expect(Costmap.fromMessage(grid(2000, 1000, List.filled(2000 * 1000, 0))), isNull, reason: 'over 1.5 M cells');
  });

  test('colours: free and unknown see-through, cost grows, inscribed magenta, lethal red', () {
    expect(costColor(0).$4, 0);
    expect(costColor(-1).$4, 0);
    expect(costColor(250).$4, 0);
    final low = costColor(5), high = costColor(90);
    expect(high.$4, greaterThan(low.$4), reason: 'a higher cost is stronger');
    expect(high.$1, greaterThan(low.$1));
    expect(costColor(99), (194, 24, 91, 150));
    expect(costColor(100), (213, 0, 0, 170));
  });

  test('the picture has ROS row 0 at the bottom', () {
    final c = Costmap.fromMessage(grid(2, 2, [100, 0, 0, 0]))!; // row 0, col 0 is lethal
    final px = c.rgba();
    // Bottom-left pixel of the picture is index (row 1 of the picture, col 0).
    expect(px.sublist((1 * 2 + 0) * 4, (1 * 2 + 0) * 4 + 4), [213, 0, 0, 170]);
    expect(px.sublist(0, 4), [0, 0, 0, 0], reason: 'top-left is free');
  });

  test('corners place the picture in the map frame, through the costmap frame\'s transform', () {
    // 4 x 2 cells of 0.5 m with its corner at (1, 1) in odom; odom sits at (10, 0), turned 90 degrees, in map.
    corners(Pose2D toMap) => costmapCorners(origin: const Pose2D(1, 1, 0), width: 4, height: 2, resolution: 0.5, toMap: toMap);
    final plain = corners(Pose2D.identity);
    expect((plain.$1.x, plain.$1.y), (1, 2), reason: 'top-left: the grid\'s y = height edge');
    expect((plain.$2.x, plain.$2.y), (3, 2));
    expect((plain.$3.x, plain.$3.y), (1, 1));
    final turned = corners(const Pose2D(10, 0, math.pi / 2));
    expect(turned.$1.x, closeTo(8, 1e-9));
    expect(turned.$1.y, closeTo(1, 1e-9));
    expect(turned.$2.x, closeTo(8, 1e-9));
    expect(turned.$2.y, closeTo(3, 1e-9));
  });
}
