import 'package:arkit_plugin/arkit_plugin.dart';
import 'package:flutter/material.dart';
import 'package:vector_math/vector_math_64.dart' as vector;

class BodyTrackingPage extends StatefulWidget {
  @override
  _BodyTrackingPageState createState() => _BodyTrackingPageState();
}

class _BodyTrackingPageState extends State<BodyTrackingPage> {
  late ARKitController arkitController;
  final Map<ARKitSkeletonJointName, ARKitNode> jointNodes = {};

  // Define joints to track
  final List<ARKitSkeletonJointName> jointsToTrack = [
    ARKitSkeletonJointName.head,
    ARKitSkeletonJointName.leftHand,
    ARKitSkeletonJointName.rightHand,
    ARKitSkeletonJointName.leftFoot,
    ARKitSkeletonJointName.rightFoot,
    ARKitSkeletonJointName.leftShoulder,
    ARKitSkeletonJointName.rightShoulder,
    ARKitSkeletonJointName.leftArm,
    ARKitSkeletonJointName.rightArm,
    ARKitSkeletonJointName.leftForearm,
    ARKitSkeletonJointName.rightForearm,
    ARKitSkeletonJointName.spine5,
  ];

  @override
  void dispose() {
    arkitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Body Tracking Sample')),
        body: ARKitSceneView(
          configuration: ARKitConfiguration.bodyTracking,
          onARKitViewCreated: onARKitViewCreated,
        ),
      );

  void onARKitViewCreated(ARKitController arkitController) {
    this.arkitController = arkitController;
    this.arkitController.onAddNodeForAnchor = _handleAddAnchor;
    this.arkitController.onUpdateNodeForAnchor = _handleUpdateAnchor;
  }

  void _handleAddAnchor(ARKitAnchor anchor) {
    if (anchor is! ARKitBodyAnchor) {
      return;
    }

    // Create nodes for all tracked joints
    for (final joint in jointsToTrack) {
      final transform = anchor.skeleton.modelTransformsFor(joint);
      if (transform != null) {
        final node = _createSphere(transform);
        jointNodes[joint] = node;
        arkitController.add(node, parentNodeName: anchor.nodeName);
      }
    }
  }

  ARKitNode _createSphere(Matrix4 transform) {
    final position = vector.Vector3(
      transform.getColumn(3).x,
      transform.getColumn(3).y,
      transform.getColumn(3).z,
    );
    return ARKitReferenceNode(
      url: 'models.scnassets/dash.dae',
      scale: vector.Vector3.all(0.5),
      position: position,
    );
  }

  void _handleUpdateAnchor(ARKitAnchor anchor) {
    if (anchor is ARKitBodyAnchor && mounted) {
      // Update all tracked joint positions
      for (final joint in jointsToTrack) {
        final transform = anchor.skeleton.modelTransformsFor(joint);
        if (transform != null && jointNodes.containsKey(joint)) {
          final position = vector.Vector3(
            transform.getColumn(3).x,
            transform.getColumn(3).y,
            transform.getColumn(3).z,
          );
          jointNodes[joint]?.position = position;
        }
      }
    }
  }
}
