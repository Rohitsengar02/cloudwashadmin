import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/dio.dart';

final bookingsRepositoryProvider = Provider((ref) => BookingsRepository());

class BookingsRepository {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  Future<void> updateBookingStatus(
    String orderId,
    String status, {
    String? userId,
  }) async {
    try {
      final updates = {
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      };

      // 1. Update in main orders collection
      await _firestore.collection('orders').doc(orderId).update(updates);

      // 2. Update in user's orders subcollection if userId is known
      String? actualUserId = userId;

      // If userId wasn't provided, try to find it from the main order document
      if (actualUserId == null) {
        final doc = await _firestore.collection('orders').doc(orderId).get();
        actualUserId = doc.data()?['userId'];
      }

      if (actualUserId != null) {
        await _firestore
            .collection('users')
            .doc(actualUserId)
            .collection('orders')
            .doc(orderId)
            .update(updates);

        // 3. Create a notification for the user
        await _firestore.collection('notifications').add({
          'userId': actualUserId,
          'title': 'Booking Update',
          'message': 'Your booking #$orderId is now $status',
          'orderId': orderId,
          'status': status,
          'type': 'order_update',
          'isRead': false,
          'createdAt': FieldValue.serverTimestamp(),
        });

        // 4. Send PUSH Notification (Directly from Client - Legacy API)
        await _sendDirectFCM(
          userId: actualUserId,
          title: 'Booking Update',
          body: 'Your booking #$orderId is now $status',
          data: {'orderId': orderId, 'status': status},
        );
      }

      print('✅ Order $orderId status updated to $status in Firestore');
    } catch (e) {
      print('❌ Firebase update status error: $e');
      throw Exception('Failed to update status in Firebase: $e');
    }
  }

  // 👇 CLIENT-SIDE FCM SENDING (FREE ALTERNATIVE to Cloud Functions)
  // ⚠️ SECURITY WARNING: Putting Server Key in client code is risky.
  // Use strictly for Admin Internal App or Prototyping.
  // Enable "Cloud Messaging API (Legacy)" in Firebase Console to get the key.
  Future<void> _sendDirectFCM({
    required String userId,
    required String title,
    required String body,
    required Map<String, dynamic> data,
  }) async {
    try {
      // 1. Get User's Token
      final userDoc = await _firestore.collection('users').doc(userId).get();
      final fcmToken = userDoc.data()?['fcmToken'];

      if (fcmToken == null) {
        print('⚠️ No FCM Token found for user $userId. Skipping Push.');
        return;
      }

      // 2. Send Request using HTTP/Dio
      // We create a temporary Dio instance here since we don't have it injected
      final dio = Dio();

      // 🛑 REPLACE [YOUR_SERVER_KEY] BELOW WITH YOUR ACTUAL KEY
      // Go to Firebase Console -> Project Settings -> Cloud Messaging -> Cloud Messaging API (Legacy)
      // If disabled, click 3 dots -> Manage API -> Enable
      const serverKey = '1whaT0eurFKKuN3A3EbXR48ECI_H0bpGtCRHuQwU3uE';

      if (serverKey == 'YOUR_FCM_SERVER_KEY_HERE') {
        print(
            '⚠️ FCM Server Key not set. Please update BookingsRepository with your key.');
        return;
      }

      final response = await dio.post(
        'https://fcm.googleapis.com/fcm/send',
        options: Options(
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'key=$serverKey',
          },
        ),
        data: {
          'to': fcmToken,
          'notification': {
            'title': title,
            'body': body,
            'sound': 'default', // Plays sound on iOS/Android
          },
          'data': {
            'click_action': 'FLUTTER_NOTIFICATION_CLICK',
            ...data,
          },
          'priority': 'high',
        },
      );

      print(
          '📨 FCM Direct Send Response: ${response.statusCode} - ${response.data}');
    } catch (e) {
      print('❌ Error sending direct FCM: $e');
    }
  }
}
