streams:
  kombuis:
    - rtsp://__RTSP_USER__:__RTSP_PASS__@@192.168.1.128:554/Streaming/Channels/201/
  Inrit:
    - rtsp://__RTSP_USER__:__RTSP_PASS__@@192.168.1.128:554/Streaming/Channels/101/ 
  Agter:
    - rtsp://__RTSP_USER__:__RTSP_PASS__@@192.168.1.128:554/Streaming/Channels/301/    

api:
  listen: ":1984"

rtsp:
  listen: ":8554"
