import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_im/model/chat.dart';
import 'package:flutter_im/model/my_info.dart';
import 'package:flutter_im/model/socket_message.dart';
import 'package:flutter_im/util/database_manager.dart';
import 'package:flutter_im/util/socket_notifier.dart';

/// @author wu chao
/// @project flutter_im
/// @date 2021/8/14
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:socket_io_client/socket_io_client.dart';
import 'package:uuid/uuid.dart';

const CONNECT_INFO = "connect_info";
const ENTER_SERVER = "enter_server";
const CS_CP2P_S = "cs_cp2p_s";
const CS_CP2P_SR = "cs_cp2p_sr";
const PONG = "pong";
const CS_GCDS_SR = "cs_gcds_sr";

//webSocket逻辑管理
class SocketManager {
  static final SocketManager _instance = SocketManager.internal();

  SocketManager.internal();

  factory SocketManager() => _instance;

  late IO.Socket socket;

  bool enterFlag = false;

  bool pingWaitFlag = false;

  int pingWaitTime = 0;

  String socketUrl = "";

  Timer? pingTimer;

  Timer? pingWaitTimer;

  String chatID = '';

  getSocketAddress() async {
    Map<String, dynamic> optHeader = {
      'token': MyInfo.token,
    };
    Dio dio = Dio(BaseOptions(connectTimeout: 30000, headers: optHeader));
    var response = await dio.post('');
    debugPrint(response.toString());
    if (response.data["code"] != 1000) {
      debugPrint("获取地址失败");
      return;
    }
    socketUrl = response.data["data"]["server"];
  }

  openSocket() {
    //创建socket io链接对象
    socket = IO.io(
        socketUrl,
        OptionBuilder()
            .setTransports(['websocket']) // for Flutter or Dart VM
            .setExtraHeaders({'x-access-token': MyInfo.token})
            .setPath("/connector")
            .setQuery({"room_id": "", "room_type": "lobby"}) // optional
            .build());
    socket.onDisconnect((data) {
      debugPrint("onDisconnect");
      debugPrint(data.toString());
    });
    socket.onConnectError((data) {
      debugPrint("onConnectError");
      debugPrint(data.toString());
    });
    socket.onConnectTimeout((data) {
      debugPrint("onConnectTimeout");
      debugPrint(data.toString());
    });
    socket.onError((data) {
      debugPrint("onError");
      debugPrint(data.toString());
    });
    socket.on('message', (data) {
      debugPrint("message");
      debugPrint(data.toString());
      SocketMessage socketMessage = socketMessageFromJson(data);
      switch (socketMessage.type) {
        case CONNECT_INFO:
          enter();
          break;
        case ENTER_SERVER:
          enterFlag = true;
          pingWaitFlag = false;
          pingWaitTime = 0;
          if (pingWaitTimer != null) pingWaitTimer!.cancel();
          if (pingTimer != null) pingTimer!.cancel();
          heart();
          break;
        case CS_GCDS_SR:
          DatabaseManager()
              .insertChatDetail(
                  chatDetailFromGCDSSocketJson(socketMessage.payload["datas"]))
              .then((value) {
            P2PNotifier().notice();
          });
          break;
        case CS_CP2P_S:
          ChatList newChat = ChatList.fromSocketJson(socketMessage.payload);
          ChatDetail chatDetail =
              ChatDetail.fromP2PSocketJson(socketMessage.payload);
          DatabaseManager().insertChatDetail([chatDetail]).then((value) {
            if (newChat.chatObjectId == chatID) P2PNotifier().notice();
          });
          DatabaseManager()
              .selectChatListForID(socketMessage.payload["from_id"])
              .then((chat) {
            print("chat:$chat");
            if (chat.length == 0) {
              DatabaseManager().insertChatList([newChat]);
            }
            if (chat.length != 0 && newChat.chatObjectId != chatID) {
              newChat.unreadCount +=
                  int.parse(chat[0]["unread_count"].toString());
              DatabaseManager().updateChatList(newChat);
            }
            P2PNotifier().notice();
          });
          break;
        case CS_CP2P_SR:
          DatabaseManager().updateChatDetailStatus(
              json.decode(data)["payload"]["doc_id"],
              json.decode(data)["payload"]["r_id"]);
          P2PNotifier().notice();
          break;
      }
    });
    socket.on('response', (data) {
      debugPrint("response");
      debugPrint(data);
      SocketMessage socketMessage = socketMessageFromJson(data);
      if (socketMessage.type == PONG && socketMessage.code == 1000) {
        pingWaitFlag = false;
        pingWaitTimer!.cancel();
        pingWaitTime = 0;
      }
    });
    socket.onConnect((_) {
      print('connect');
    });
  }

  heart() {
    pingTimer = Timer.periodic(Duration(seconds: 30), (data) {
      if (pingWaitTime >= 60) {
        socket.connect();
        pingWaitTime = 0;
        pingWaitTimer!.cancel();
        ping();
      }
      if (!pingWaitFlag) ping();
    });
  }

  ping() {
    debugPrint("ping");
    String pingData =
        '{"type":"ping","payload":{"front":true},"msg_id":${DateTime.now().millisecondsSinceEpoch}}';
    socket.emit("message", pingData);
    pingWaitFlag = true;
    pingWaitTime = 0;
    pingWaitTimer = Timer.periodic(Duration(seconds: 1), (data) {
      pingWaitTime++;
      print(data.hashCode);
      if (pingWaitTime % 10 == 0) debugPrint(pingWaitTime.toString());
    });
  }

  enter() {
    String enterData =
        '{"type":"enter","payload":{"extra":{"lg":"zh","pt":"android","sv":77,"tz":"+08:00","v":202108100},"from":"","password":"","room_id":"","token":"${MyInfo.token}","type":"lobby","user":{"avatar":"https:\\/\\/werewolf-image.xiaobanhui.com\\/default\\/female_wolf.png?imageView2%2F0%2Fw%2F1920%2Fh%2F1080%2Fq%2F75%7Cimageslim","experience":0,"id":"${MyInfo.id}","level":0,"name":"519237","sex":1}},"msg_id":"${DateTime.now().millisecondsSinceEpoch}"}';
    socket.emit("message", enterData);
  }

  talk(talkData) {
    socket.emit("message", talkData);
  }

  getChatDetail(String chatObjectId, {String formID = ''}) {
    if (formID != '') return;
    socket.emit("message",
        '{"msg_id":"${Uuid().v1().replaceAll("-", "")}","payload":{"cType":1,"tid":"$chatObjectId","limit":30},"type":"cs_gcds"}');
    //,"form_id":"611a2d21c71e7621997d5594"
  }

  inChat(String chatObjectId) {
    socket.emit("message",
        '{"msg_id":"${Uuid().v1().replaceAll("-", "")}","payload":{"cType":1,"tid":"$chatObjectId"},"type":"cs_ain"}');
  }

  leaveChat(String chatObjectId) {
    socket.emit("message",
        '{"msg_id":"${Uuid().v1().replaceAll("-", "")}","payload":{"cType":1,"tid":"$chatObjectId"},"type":"cs_alv"}');
  }
}
