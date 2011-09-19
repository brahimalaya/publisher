-module(publish_encoder).
-author('Max Lapshin <max@maxidoors.ru>').

-behaviour(gen_server).
-include_lib("erlmedia/include/video_frame.hrl").
-include_lib("erlmedia/include/media_info.hrl").


%% External API
-export([start_link/1, start_link/2]).
-export([x264_helper/2, faac_helper/2]).
-export([status/1, subscribe/1]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(encoder, {
  clients = [],
  options,
  uvc,
  x264,
  audio,
  faac,
  width,
  height,
  rtmp,
  start,
  stream,
  buffer = [],
  aconfig,
  vconfig,
  last_dts,
  audio_count = 0,
  video_count = 0
}).


start_link(Options) ->
  gen_server:start_link(?MODULE, [Options], []).

start_link(Name, Options) ->
  gen_server:start_link({local, Name}, ?MODULE, [Options], []).

status(Encoder) ->
  gen_server:call(Encoder, status).
  
subscribe(Encoder) ->
  erlang:monitor(process, Encoder),
  gen_server:call(Encoder, {subscribe, self()}).

init([Options]) ->
  process_flag(trap_exit, true),
  
  Encoder1 = #encoder{options = Options},
  
  Encoder2 = start_h264_capture(Encoder1),
  Encoder3 = start_aac_capture(Encoder2),
  
  
  
  {ok, Encoder3#encoder{
    last_dts = 0,
    start = erlang:now()
  }}.

start_h264_capture(#encoder{options = Options} = Encoder) ->
  case proplists:get_value(h264_source, Options, uvc) of
    uvc -> start_uvc_capture(Encoder);
    {ems, _} -> start_erlyvideo_capture(Encoder)
  end.

start_uvc_capture(#encoder{options = Options} = Encoder) ->
  {ok, UVC} = uvc:capture([{format,yuv},{consumer,self()}|Options]),
  put(uvc_debug, proplists:get_value(debug, Options)),
  {W,H} = proplists:get_value(size, Options),
  H264Config = proplists:get_value(h264_config, Options, "h264/encoder.preset"),
  X264Options = [{width,W},{height,H},{config,H264Config},{annexb,false}|Options],
  {ok, X264, VConfig} = proc_lib:start_link(?MODULE, x264_helper, [self(), X264Options]),
  Encoder#encoder{uvc = UVC, vconfig = VConfig, width = W, height = H, x264 = X264}.


start_erlyvideo_capture(#encoder{options = Options} = Encoder) ->
  {ems, {URL, Type, Args}} = proplists:get_value(h264_source, Options),
  {ok, Media} = ems_media:start_link(Type, [{url,URL}|Args]),
  #media_info{video = [#stream_info{config = VConfig}]} = ems_media:media_info(Media),
  Encoder#encoder{vconfig = VConfig, x264 = Media}.

start_aac_capture(#encoder{options = Options} = Encoder) ->
  SampleRate = proplists:get_value(sample_rate, Options, 32000),
  Channels = proplists:get_value(channels, Options, 2),
  {ok, Capture} = alsa:start(SampleRate, Channels),
  AACOptions = [{sample_rate,SampleRate},{channels,Channels}],
  {ok, AACEnc, AConfig} = proc_lib:start_link(?MODULE, faac_helper, [self(), AACOptions]),
  Encoder#encoder{audio = Capture, aconfig = AConfig, faac = AACEnc}.


x264_helper(Master, Options) ->
  {ok, X264, VConfig} = x264:init(Options),
  erlang:monitor(process, Master),
  proc_lib:init_ack({ok, self(), VConfig}),
  x264_loop(Master, X264).

x264_loop(Master, X264) ->
  receive
    keyframe ->
      x264_loop(Master, X264);
      
    {yuv, YUV, PTS} ->
      drop(),
      case x264:encode(X264, YUV, PTS) of
        undefined -> ok;
        #video_frame{} = Frame -> Master ! Frame
      end,
      x264_loop(Master, X264);
    Else ->
      io:format("x264_loop is stopping: ~p~n", [Else])
  end.


faac_helper(Master, Options) ->
  {ok, AACEnc, AConfig} = faac:init(Options),
  erlang:monitor(process, Master),
  proc_lib:init_ack({ok, self(), AConfig}),
  put(prev_pts, 0),
  faac_loop(Master, AACEnc).


faac_loop(Master, AAC) ->
  receive
    {alsa, PCM, PTS} ->
      case faac:encode(AAC, PCM) of
        undefined -> ok;
        #video_frame{} = AFrame ->
          PrevPts = get(prev_pts),
          if PrevPts > PTS -> io:format("Damn! backjump of audio ~p ~p ~n", [get(prev_pts), PTS]);
            true -> ok
          end,
          put(prev_pts, PTS),
          Master ! AFrame#video_frame{dts = PTS, pts = PTS}
      end,
      faac_loop(Master, AAC);
    Else ->
      io:format("faac_loop is stopping: ~p~n", [Else])  
  end.


drop() ->
  {message_queue_len,Len} = process_info(self(), message_queue_len),
  Count = if
    Len > 100 -> drop(all, 0);
    Len > 30 -> drop(3, 0);
    Len > 10 -> drop(1, 0);
    true -> 0
  end,
  if
    Count > 0 -> error_logger:warning_msg("Drop ~p frames in publisher~n", [Count]);
    true -> ok
  end.
  


drop(Limit, Count) when is_number(Limit) andalso is_number(Count) andalso Count >= Limit ->
  Count;

drop(Limit, Count) ->
  receive
    {uvc, _UVC, _Codec, _PTS, _Jpeg} -> drop(Limit, Count + 1);
    {yuv, _YUV, _PTS} -> drop(Limit, Count + 1)
  after
    0 -> Count
  end.



handle_call(status, _From, #encoder{buffer = Buf, start = Start} = State) ->
  Status = [
    {buffer, [{C,D} || #video_frame{codec = C, dts = D} <- Buf]},
    {buffered_frames, length(Buf)},
    {abs_delta, timer:now_diff(erlang:now(), Start) div 1000}
  ],
  {reply, Status, State};

handle_call({subscribe, Client}, _From, #encoder{clients = Clients, aconfig = AConfig, vconfig = VConfig, x264 = X264, last_dts = DTS} = State) ->
  Client ! AConfig#video_frame{dts = DTS, pts = DTS},
  Client ! VConfig#video_frame{dts = DTS, pts = DTS},
  X264 ! keyframe,
  erlang:monitor(process, Client),
  {reply, ok, State#encoder{clients = [Client|Clients]}};
  

handle_call(Request, _From, State) ->
  {stop, {unknown_call, Request}, State}.

handle_cast(_Msg, State) ->
  {stop, {unknown_cast, _Msg}, State}.


-define(THRESHOLD, 10000).
check_frame_delay(#video_frame{dts = DTS} = Frame, Frames) ->
  case [true || #video_frame{dts = D} <- Frames, abs(D - DTS) > ?THRESHOLD] of
    [] -> true;
    _ ->
      io:format("Frame ~p delayed: ~p~n", [Frame, [{C,D} || #video_frame{codec = C, dts = D} <- Frames]]),
      false
  end.

enqueue(#video_frame{} = Frame, #encoder{buffer = Buf1, clients = Clients, start = Start} = State) ->
  Buf2 = lists:keysort(#video_frame.dts, [Frame|Buf1]),
  AbsDelta = timer:now_diff(erlang:now(), Start) div 1000,
  {Buf3, ToSend} = try_flush(Buf2, []),
  lists:foreach(fun(F1) ->
    case get(uvc_debug) of
      true ->
        io:format("~4s ~8B ~8B ~8B ~8B~n", [F1#video_frame.codec, F1#video_frame.dts, F1#video_frame.pts, AbsDelta, AbsDelta - F1#video_frame.dts]);
      _ -> ok
    end,
    [Client ! F1 || Client <- Clients]
  end, ToSend),
  State#encoder{buffer = Buf3}.

try_flush([F1|F2] = Frames, ToSend) ->
  Contents = [C || #video_frame{content = C} <- Frames],
  HasVideo = lists:member(video, Contents),
  HasAudio = lists:member(audio, Contents),
  if
    HasVideo andalso HasAudio -> try_flush(F2, [F1|ToSend]);
    true -> {Frames, lists:reverse(ToSend)}
  end.


handle_info({uvc, _UVC, yuv, PTS1, YUV}, State) ->
  case get(start_uvc_pts) of
    undefined -> put(start_uvc_pts, PTS1);
    _ -> ok
  end,
  PTS = PTS1 - get(start_uvc_pts),
  drop(),
  % T1 = erlang:now(),
  % PTS = timer:now_diff(T1, State#encoder.start) div 1000,  
  handle_info({yuv, YUV, PTS}, State);

handle_info(#video_frame{} = Frame, #encoder{} = State) ->
  case check_frame_delay(Frame, State#encoder.buffer) of
    true -> {noreply, enqueue(Frame, State)};
    false -> {noreply, State}
  end;

handle_info({yuv, YUV, PTS}, #encoder{x264 = X264} = State) ->
  X264 ! {yuv, YUV, PTS},

  VideoCount = State#encoder.video_count + 1,
  % ?D({v,VideoCount, VideoCount*50, timer:now_diff(erlang:now(),State#encoder.start) div 1000, Drop}),
  {noreply, State#encoder{video_count = VideoCount}};

handle_info({alsa, _Capture, DTS, PCM}, #encoder{faac = AACEnc} = State) ->
  AACEnc ! {alsa, PCM, DTS},

  % AudioCount = State#encoder.audio_count + (size(PCM) div 2),
  % AbsDelta = timer:now_diff(erlang:now(),State#encoder.start) div 1000,
  % StreamDelta = State#encoder.audio_count div (32*2),
  % ?D({a, DTS, StreamDelta, AbsDelta, AbsDelta - StreamDelta}),
  AudioCount = State#encoder.audio_count + 1,
  {noreply, State#encoder{audio_count = AudioCount}};

handle_info({'DOWN', _, process, Client, _Reason}, #encoder{clients = Clients} = Server) ->
  {noreply, Server#encoder{clients = lists:delete(Client, Clients)}};

handle_info(_Info, State) ->
  {stop, {unknown_message, _Info}, State}.

terminate(_Reason, #encoder{audio = Alsa}) ->
  alsa:stop(Alsa),
  ok.

code_change(_OldVsn, State, _Extra) ->
  {ok, State}.
