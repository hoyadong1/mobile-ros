# 가짜 로봇 (실물 로봇 없이 앱 검증)

실제 ROS 2 스택으로 검증하려면 WSL에서 `bash scripts/ros2_sim.sh`를 쓰세요(맨 위 주석의 apt 설치 필요).
이 문서의 `fake_robot.py`는 ROS 설치 없이 빠르게 확인하는 **가짜 rosbridge 로봇**입니다.
rosapi, 차동구동 로봇, 카메라, 지도, 목표 수신을 흉내 내며 기본은 ROS 2(`--ros 1`로 ROS 1)입니다.

## 준비

```sh
python -m pip install websockets
```

RTSP까지 시험하려면 ffmpeg(PATH에 있어야 함)와 MediaMTX가 필요합니다.
MediaMTX는 `.tools/mediamtx/mediamtx.exe`에 두면 자동으로 찾습니다(`.tools/`는 git 제외 대상).
<https://github.com/bluenviron/mediamtx/releases>에서 `windows_amd64.zip`을 받아 압축을 풀면 됩니다.

## 실행

```sh
python scripts/fake_robot.py --port 9091 --rtsp --map-yaw 30 --image-pad 4
```

- `--ros 2|1`: 흉내 낼 ROS 버전. ROS 2는 `/goal_pose`, ROS 1은 `/move_base/goal`로 목표를 받습니다.
- `--port`: 9090은 이 PC에서 WSL 포트 프록시가 이미 쓰고 있어 9091을 권장합니다.
- `--rtsp`: `rtsp://<PC IP>:8554/test`로 테스트 패턴 영상 송출
- `--map-yaw`: 지도 원점 회전(도). 회전된 지도에서 목표 좌표 변환을 검증합니다.
- `--image-encoding rgb8|bgr8|rgba8|bgra8|mono8`, `--image-pad N`: 인코딩·행 패딩 처리 검증

처음 실행할 때 Windows 방화벽이 Python/MediaMTX 허용 여부를 물으면 **개인 네트워크**를 허용하세요.
휴대폰은 PC와 같은 Wi‑Fi에 연결하고, 앱에는 시작 로그의 `[READY]` 줄에 나온 PC IP와 포트를 입력합니다.

## 무엇을 확인하나

| 앱 화면 | 기대 결과 | 서버 로그 |
|---|---|---|
| 연결 | 접속 성공 | `[CONNECT]` |
| ROS Lists | 노드 5개, 토픽 9개, 서비스 목록, 노드 상세 | `[SERVICE] /rosapi/... -> ok` |
| 토픽 구독 | `/chatter` 1초마다 갱신 | `[SUBSCRIBE] /chatter` |
| Control – ROS image | 좌상 빨강, 우상 초록, 좌하 파랑, 우하 흰색 + 움직이는 노란 막대 | `[SUBSCRIBE] /camera/color/image_raw` |
| Control – RTSP | 컬러 테스트 패턴과 타이머 | (MediaMTX) |
| Control – 조이스틱 | 손 떼면/정지 버튼/화면 나가면 정지 | `[CMD_VEL] ...`, `STOP (zero twist) received` |
| Map View | 벽·기둥·선반, 우상단 미지 영역, 로봇 위치 | `[SUBSCRIBE] /map` 등 |
| Map – 목표 전송 | 화면에 `Navigation: ROS 2 Nav2 (/goal_pose)` 표시, 로봇이 목표로 이동 | `[GOAL] received map (x, y) -> grid cell ... = free`, `reached` |
| Message Publish | 발행 내용 표시, 미광고 토픽은 오류 | `[PUBLISH] ...`, `[STATUS->ERROR]` |

빨강/파랑이 뒤바뀌어 보이면 RGB/BGR 변환 버그, 목표 로그의 grid cell이 탭한 위치와 다르면
지도 좌표 변환 버그입니다. 목표 로그는 그 칸이 free/occupied/unknown인지도 알려 줍니다.

## 한계

실제 ROS 노드가 아니라 프로토콜 흉내입니다. 충돌·경로계획이 없어 로봇은 벽을 통과하고,
내비게이션 결과/상태 토픽은 발행하지 않습니다. 최종 확인은 실제 rosbridge(가능하면 실기)로 해야 합니다.
