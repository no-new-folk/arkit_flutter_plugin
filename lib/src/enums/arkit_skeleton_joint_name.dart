enum ARKitSkeletonJointName {
  // Root
  root,

  // Hips
  hips,

  // Spine
  spine1,
  spine2,
  spine3,
  spine4,
  spine5,
  spine6,
  spine7,

  // Neck and Head
  neck1,
  neck2,
  neck3,
  neck4,
  head,

  // Left Shoulder and Arm
  leftShoulder,
  leftArm,
  leftForearm,
  leftHand,

  // Right Shoulder and Arm
  rightShoulder,
  rightArm,
  rightForearm,
  rightHand,

  // Left Leg
  leftUpLeg,
  leftLeg,
  leftFoot,
  leftToeBase,

  // Right Leg
  rightUpLeg,
  rightLeg,
  rightFoot,
  rightToeBase,

  // Left Hand Fingers - Thumb
  leftHandThumb1,
  leftHandThumb2,
  leftHandThumb3,
  leftHandThumbTip,

  // Left Hand Fingers - Index
  leftHandIndex1,
  leftHandIndex2,
  leftHandIndex3,
  leftHandIndexTip,

  // Left Hand Fingers - Middle
  leftHandMiddle1,
  leftHandMiddle2,
  leftHandMiddle3,
  leftHandMiddleTip,

  // Left Hand Fingers - Ring
  leftHandRing1,
  leftHandRing2,
  leftHandRing3,
  leftHandRingTip,

  // Left Hand Fingers - Little
  leftHandLittle1,
  leftHandLittle2,
  leftHandLittle3,
  leftHandLittleTip,

  // Right Hand Fingers - Thumb
  rightHandThumb1,
  rightHandThumb2,
  rightHandThumb3,
  rightHandThumbTip,

  // Right Hand Fingers - Index
  rightHandIndex1,
  rightHandIndex2,
  rightHandIndex3,
  rightHandIndexTip,

  // Right Hand Fingers - Middle
  rightHandMiddle1,
  rightHandMiddle2,
  rightHandMiddle3,
  rightHandMiddleTip,

  // Right Hand Fingers - Ring
  rightHandRing1,
  rightHandRing2,
  rightHandRing3,
  rightHandRingTip,

  // Right Hand Fingers - Little
  rightHandLittle1,
  rightHandLittle2,
  rightHandLittle3,
  rightHandLittleTip,
}

extension ARKitSkeletonJointNameX on ARKitSkeletonJointName {
  String toJointNameString() {
    final name = toString().split('.').last;

    // Convert camelCase to snake_case with _joint suffix
    // e.g., leftHand -> left_hand_joint, spine1 -> spine_1_joint
    final buffer = StringBuffer();

    for (int i = 0; i < name.length; i++) {
      final char = name[i];

      if (i > 0 && char == char.toUpperCase() && char != char.toLowerCase()) {
        buffer.write('_');
        buffer.write(char.toLowerCase());
      } else if (i > 0 &&
                 i < name.length - 1 &&
                 char.contains(RegExp(r'[0-9]')) &&
                 !name[i - 1].contains(RegExp(r'[0-9]'))) {
        buffer.write('_');
        buffer.write(char);
      } else {
        buffer.write(char.toLowerCase());
      }
    }

    return '${buffer.toString()}_joint';
  }
}
