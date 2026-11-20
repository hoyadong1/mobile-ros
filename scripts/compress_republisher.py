#!/usr/bin/env python3
"""Stand-in for `ros2 run image_transport republish raw compressed` when the official
compressed_image_transport plugin is not installed: subscribes to a raw sensor_msgs/Image and publishes
sensor_msgs/CompressedImage on <topic>/compressed with the same `format` string the plugin uses
("<encoding>; jpeg compressed bgr8"), JPEG quality 80.

Usage (in WSL, ROS sourced):  python3 scripts/compress_republisher.py /camera/image_raw
"""
import sys

import cv2
import numpy as np
import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from sensor_msgs.msg import CompressedImage, Image


class Republisher(Node):
    def __init__(self, topic):
        super().__init__('compress_republisher')
        self.pub = self.create_publisher(CompressedImage, topic + '/compressed', 10)
        self.create_subscription(Image, topic, self.on_image, qos_profile_sensor_data)
        self.get_logger().info(f'{topic} -> {topic}/compressed (JPEG q80)')

    def on_image(self, msg):
        channels = {'mono8': 1, 'rgb8': 3, 'bgr8': 3, 'rgba8': 4, 'bgra8': 4}.get(msg.encoding)
        if channels is None:
            return
        rows = np.frombuffer(msg.data, np.uint8).reshape(msg.height, msg.step)
        img = rows[:, :msg.width * channels].reshape(msg.height, msg.width, channels)
        if msg.encoding == 'rgb8':
            img = cv2.cvtColor(img, cv2.COLOR_RGB2BGR)
        elif msg.encoding == 'rgba8':
            img = cv2.cvtColor(img, cv2.COLOR_RGBA2BGR)
        elif msg.encoding == 'bgra8':
            img = cv2.cvtColor(img, cv2.COLOR_BGRA2BGR)
        ok, jpeg = cv2.imencode('.jpg', img, [cv2.IMWRITE_JPEG_QUALITY, 80])
        if not ok:
            return
        out = CompressedImage()
        out.header = msg.header
        out.format = f'{msg.encoding}; jpeg compressed bgr8'
        out.data = jpeg.tobytes()
        self.pub.publish(out)


def main():
    rclpy.init()
    rclpy.spin(Republisher(sys.argv[1] if len(sys.argv) > 1 else '/camera/image_raw'))


if __name__ == '__main__':
    main()
