unit Game;

interface

uses
  Generics.Collections, GameServerPlayer, defs, PangyaBuffer, utils, ClientPacket, SysUtils,
  GameHoleInfo;

type

  TPlayerCreateGameInfo = packed record
    un1: UInt8;
    turnTime: UInt32;
    gameTime: UInt32;
    maxPlayers: UInt8;
    gameType: TGAME_TYPE;
    holeCount: byte;
    map: UInt8;
    mode: TGAME_MODE;
    naturalMode: cardinal;
  end;

  TGame = class;

  TGameEvent = TEvent<TGame>;

  TGameGenericEvent = class
    private
      var m_event: TGameEvent;
    public
      procedure Trigger(game: TGame);
      property Event: TGameEvent read m_event write m_event;
      constructor Create;
      destructor Destroy; override;
  end;

  TGame = class
    private
      var m_id: UInt16;
      var m_players: TList<TGameClient>;

      var m_name: AnsiString;
      var m_password: AnsiString;
      var m_gameInfo: TPlayerCreateGameInfo;
      var m_artifact: UInt32;
      var m_gameStarted: Boolean;
      var m_rain_drop_ratio: UInt8;

      var m_gameKey: array [0 .. $F] of ansichar;

      var m_game_holes: TList<TGameHoleInfo>;

      var m_onUpdateGame: TGameGenericEvent;

      procedure generateKey;
      function FGetPlayerCount: UInt16;
      procedure TriggerGameUpdated;
      procedure RandomizeWeather;
      procedure RandomizeWind;
      procedure DecryptShot(data: PansiChar; size: UInt32);

    public
      property Id: UInt16 read m_id write m_id;
      property PlayerCount: Uint16 read FGetPlayerCount;

      constructor Create(name, password: AnsiString; gameInfo: TPlayerCreateGameInfo; artifact: UInt32; onUpdate: TGameEvent);
      destructor Destroy; override;

      function AddPlayer(player: TGameClient): Boolean;
      function RemovePlayer(player: TGameClient): Boolean;
      function GameInformation: AnsiString;
      function GameResume: AnsiString;

      procedure Send(data: AnsiString); overload;
      procedure Send(data: TPangyaBuffer); overload;

      function playersData: AnsiString;

      procedure HandlePlayerLoadingInfo(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerHoleInformations(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerLoadOk(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerReady(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerStartGame(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerChangeGameSettings(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayer1stShotReady(const client: TGameClient; const clientPacket: TClientPacket);

      procedure HandlePlayerActionShot(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerActionRotate(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerActionHit(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerActionChangeClub(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerShotData(const client: TGameClient; const clientPacket: TClientPacket);
      procedure HandlePlayerShotSync(const client: TGameClient; const clientPacket: TClientPacket);

  end;

implementation

uses GameServerExceptions, Buffer, ConsolePas, PangyaPacketsDef, ShotData;

constructor TGameGenericEvent.Create;
begin
  inherited Create;
end;

destructor TGameGenericEvent.Destroy;
begin
  inherited;
end;

procedure TGameGenericEvent.Trigger(game: TGame);
begin
  if Assigned(m_event) then
  begin
    m_event(game);
  end;
end;

constructor TGame.Create(name, password: AnsiString; gameInfo: TPlayerCreateGameInfo; artifact: UInt32; onUpdate: TGameEvent);
var
  I: Integer;
begin
  m_onUpdateGame := TGameGenericEvent.Create;

  m_game_holes := TList<TGameHoleInfo>.Create;

  for I := 1 to 18 do
  begin
    m_game_holes.Add(TGameHoleInfo.Create);
  end;

  m_onUpdateGame.Event := onUpdate;
  m_name := name;
  m_password := password;
  m_gameInfo := gameInfo;
  m_artifact := artifact;
  m_players := TList<TGameClient>.Create;
  m_gameStarted := false;
  m_rain_drop_ratio := 10;
  generateKey;
end;

destructor TGame.Destroy;
var
  holeInfo: TGameHoleInfo;
begin
  inherited;

  for holeInfo in m_game_holes do
  begin
    TObject(holeInfo).Free;
  end;

  m_players.Free;
  m_onUpdateGame.Free;
end;

function TGame.AddPlayer(player: TGameClient): Boolean;
var
  gamePlayer: TGameClient;
  playerIndex: integer;
  res: TClientPacket;
begin
  if m_players.Count >= m_gameInfo.maxPlayers then
  begin
    raise GameFullException.CreateFmt('Game (%d) is full', [Id]);
  end;

  playerIndex := m_players.Add(player);
  player.Data.Data.playerInfo1.game := m_id;

  if m_id = 0 then
  begin
    Exit;
  end;

  // tmp fix, should create the list of player when a player leave the game
  player.Data.GameSlot := playerIndex + 1;

  player.Data.Action.clear;

  m_onUpdateGame.Trigger(self);

  // my player info to others in game
  self.Send(
    #$48#$00 + #$01#$FF#$FF +
    player.Data.GameInformation
  );

  // game informations for me
  player.Send(
    #$49#$00 + #$00#$00 +
    self.GameInformation
  );

  self.TriggerGameUpdated;

  // player lobby informations
  self.Send(
    #$46#$00 +
    #$03#$01 +
    player.Data.LobbyInformations
  );

  res := TClientPacket.Create;

  res.WriteStr(#$48#$00 + #$00#$FF#$FF);

  res.WriteUInt8(UInt8(m_players.Count));

  // Other player in game information to me
  for gamePlayer in m_players do
  begin
    res.WriteStr(gamePlayer.Data.GameInformation);
  end;

  res.WriteUInt8(0); // <- seem important

  self.Send(res);

  res.Free;

  Exit(true);
end;

function TGame.RemovePlayer(player: TGameClient): Boolean;
begin
  if m_players.Remove(player) = -1 then
  begin
    raise PlayerNotFoundException.CreateFmt('Game (%d) can''t remove player with id %d', [player.Data.Data.playerInfo1.PlayerID]);
    Exit(false);
  end;
  player.Data.Data.playerInfo1.game := $FFFF;

  if m_id = 0 then
  begin
    Exit;
  end;

  self.Send(
    #$48#$00 + #$02 + #$FF#$FF +
    player.Data.GameInformation(0)
  );

  m_onUpdateGame.Trigger(self);

  Exit(true);
end;

procedure TGame.generateKey;
var
  I: Integer;
begin
  randomize;
  for I := 0 to length(m_gameKey) - 1 do begin
    m_gameKey[I] := ansichar(random($F));
  end;
end;

function TGame.GameInformation: AnsiString;
var
  packet: TClientPacket;
  pl: integer;
  plTest: boolean;
  val: UInt8;
  testResult: UInt8;
begin
  packet := TClientPacket.Create;

  packet.WriteStr(
    m_name, 27, #$00
  );

  packet.WriteStr(
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00
  );

  pl := Length(m_password);
  plTest := pl > 0;

  packet.WriteUInt8(TGeneric.Iff(plTest, 0, 1));
  packet.WriteUInt8(TGeneric.Iff(m_gameStarted, 0, 1));
  packet.WriteUInt8(0); // ?? 1 change to orange
  packet.WriteUInt8(m_gameInfo.maxPlayers);
  packet.WriteUInt8(UInt8(m_players.Count));
  packet.Write(m_gameKey[0], 16);
  packet.WriteStr(#$00#$1E);
  packet.WriteUInt8(m_gameInfo.holeCount);
  packet.WriteUInt8(UInt8(m_gameInfo.gameType));
  packet.WriteUInt16(m_id);
  packet.WriteUInt8(UInt8(m_gameInfo.mode));
  packet.WriteUInt8(m_gameInfo.map);
  packet.WriteUInt32(m_gameInfo.turnTime);
  packet.WriteUInt32(m_gameInfo.gameTime);

  packet.WriteStr(
    #$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$64#$00#$00#$00#$64#$00#$00#$00 +
    #$00#$00#$00#$00 + // game created by player id
    #$FF +
    #$00#$00#$00#$00
  );

  packet.WriteUInt32(m_gameInfo.naturalMode);

  packet.WriteStr(
    #$00#$00#$00#$00 +
    #$00#$00#$00#$00 +
    #$00#$00#$00#$00 +
    #$00#$00#$00#$00
  );

  Result := packet.ToStr;

  packet.Free;
end;

function TGame.GameResume: AnsiString;
var
  packet: TClientPacket;
begin
  packet := TClientPacket.Create;

  packet.WriteUInt8(UInt8(m_gameInfo.gameType));
  packet.WriteUInt8(m_gameInfo.map);
  packet.WriteUInt8(m_gameInfo.holeCount);
  packet.WriteUInt8(UInt8(m_gameInfo.mode));
  packet.WriteUInt32(m_gameInfo.naturalMode);
  packet.WriteUInt8(m_gameInfo.maxPlayers);
  packet.WriteStr(#$1E#$00);
  packet.WriteUInt32(m_gameInfo.turnTime);
  packet.WriteUInt32(m_gameInfo.gameTime);
  packet.WriteStr(#$00#$00#$00#$00#$00);
  packet.WritePStr(m_name);

  Result := packet.ToStr;
  packet.Free;
end;

procedure TGame.Send(data: AnsiString);
var
  client: TGameClient;
begin
  for client in m_players do
  begin
    client.Send(data);
  end;
end;

procedure TGame.Send(data: TPangyaBuffer);
var
  client: TGameClient;
begin
  for client in m_players do
  begin
    client.Send(data);
  end;
end;

function TGame.FGetPlayerCount: UInt16;
begin
  Exit(Uint16(m_players.Count));
end;

function TGame.playersData: AnsiString;
var
  player: TGameClient;
  clientPacket: TClientPacket;
  playersCount: integer;
begin
  clientPacket := TClientPacket.Create;
  playersCount := m_players.Count;

  clientPacket.WriteUInt8(playersCount);
  for player in m_players do
  begin
    clientPacket.WriteStr(player.Data.GameInformation);
    clientPacket.WriteStr(#$00);
  end;

  Result := clientPacket.ToStr;
  clientPacket.Free;
end;

procedure TGame.HandlePlayerLoadingInfo(const client: TGameClient; const clientPacket: TClientPacket);
var
  progress: UInt8;
  res: TClientpacket;
begin
  Console.Log('TGame.HandlePlayerLoadingInfo', C_BLUE);
  clientPacket.ReadUInt8(progress);

  console.Log(Format('percent loaded: %d', [progress * 10]));

  res := TClientpacket.Create;

  res.WriteStr(WriteAction(SGPID_PLAYER_LOADING_INFO));
  res.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);
  res.WriteUInt8(progress);

  self.Send(res);

  res.Free;
end;

procedure TGame.HandlePlayerHoleInformations(const client: TGameClient; const clientPacket: TClientPacket);
begin
  Console.Log('TGame.HandlePlayerHoleInformations', C_BLUE);
  Console.Log('Should do that', C_ORANGE);
end;

procedure TGame.HandlePlayerLoadOk(const client: TGameClient; const clientPacket: TClientPacket);
var
  reply: TClientPacket;
  AllPlayersReady: Boolean;
  numberOfPlayerRdy: UInt8;
  player: TGameClient;
begin
  Console.Log('TGame.HandlePlayerLoadOk', C_BLUE);
  AllPlayersReady := false;
  numberOfPlayerRdy := 0;

  client.Data.LoadComplete := true;

  for player in m_players do
  begin
    if player.Data.LoadComplete then
    begin
      Inc(numberOfPlayerRdy)
    end;
  end;

  if not (numberOfPlayerRdy = m_players.Count) then
  begin
    Exit;
  end;

  // Weather informations
  self.Send(#$9E#$00 + #$00#$00#$00);

  // Wind informations
  self.Send(#$5B#$00 + #$02#$00#$E4#$02#$01);

  reply := TClientPacket.Create;

  reply.WriteStr(#$53#$00);
  reply.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);

  // Who play
  self.Send(reply);

  reply.Free;
end;

procedure TGame.HandlePlayerReady(const client: TGameClient; const clientPacket: TClientPacket);
var
  status: UInt8;
  connectionId: UInt32;
  reply: TClientPacket;
begin
  Console.Log('TGame.HandlePlayerReady', C_BLUE);

  clientPacket.ReadUInt8(status);

  reply := TClientPacket.Create;

  reply.WriteStr(#$78#$00);
  reply.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);
  reply.WriteUInt8(status);

  self.Send(reply);

  reply.Free

end;

procedure TGame.HandlePlayerStartGame(const client: TGameClient; const clientPacket: TClientPacket);
var
  result: TClientPacket;
  player: TGameClient;
begin
  Console.Log('TGame.HandlePlayerStartGame', C_BLUE);

  m_gameStarted := true;

  self.Send(#$77#$00#$64#$00#$00#$00);

  result := TClientPacket.Create;

  result.WriteStr(#$76#$00 + #$00);
  result.WriteUInt8(UInt8(PlayerCount));

  self.RandomizeWeather;
  self.RandomizeWind;

  for player in m_players do
  begin

    with player.Data do
    begin
      ShotReady := false;
      LoadComplete := false;
      ShotSync := false;
      result.WriteStr(Data.Debug1);
    end;

  end;

  self.Send(result);

  self.Send(
    #$52#$00#$14#$00#$00#$03#$00#$00#$00#$00#$40#$9C#$00#$00#$00#$00 +
    #$00#$00#$DA#$09#$FA#$2A#$00#$14#$01#$1C#$31#$67#$C7#$01#$14#$02 +
    #$CE#$72#$3C#$58#$00#$14#$03#$00#$D7#$F9#$18#$02#$14#$04#$91#$4F +
    #$E0#$C2#$00#$14#$05#$3D#$EE#$A5#$75#$02#$14#$06#$8B#$B7#$14#$EE +
    #$01#$14#$07#$6E#$63#$89#$7A#$00#$14#$08#$64#$52#$DB#$0A#$00#$14 +
    #$09#$4D#$89#$18#$7D#$00#$14#$0A#$62#$6E#$B1#$5D#$01#$14#$0B#$2D +
    #$20#$30#$C7#$00#$14#$0C#$23#$D8#$17#$AD#$00#$14#$0D#$5F#$8F#$32 +
    #$95#$02#$14#$0E#$37#$CC#$A2#$18#$01#$14#$0F#$BE#$6C#$9E#$DF#$01 +
    #$14#$10#$13#$E8#$A1#$10#$02#$14#$11#$47#$CF#$27#$F9#$02#$14#$12 +
    #$E5#$09#$00#$00#$05#$01#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$41#$31#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$04#$00#$00#$00#$00#$00#$00#$00#$68#$12#$C4 +
    #$5A#$00#$00#$00#$00#$14#$00#$00#$00#$01#$00#$41#$31#$5C#$5F#$BD +
    #$43#$50#$CD#$8A#$C2#$2B#$BF#$04#$44#$03#$00#$00#$00#$00#$00#$00 +
    #$00#$D7#$D5#$C4#$5A#$00#$00#$00#$00#$14#$00#$00#$00#$01#$00#$41 +
    #$31#$FE#$D4#$AE#$41#$93#$D8#$BA#$C2#$04#$4E#$0B#$44#$03#$00#$00 +
    #$00#$00#$00#$00#$00#$56#$07#$C5#$5A#$00#$00#$00#$00#$14#$00#$00 +
    #$00#$01#$00#$41#$31#$C9#$B6#$96#$43#$DD#$A4#$8E#$C2#$D1#$82#$3D +
    #$C3#$03#$00#$00#$00#$00#$00#$00#$00#$C4#$9E#$C5#$5A#$00#$00#$00 +
    #$00#$14#$00#$00#$00#$01#$00#$41#$31#$AE#$F7#$C5#$43#$EC#$11#$90 +
    #$C2#$02#$0B#$E0#$43#$03#$00#$00#$00#$03#$01#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$41#$31#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00#$04#$00#$00#$00#$00#$00 +
    #$00#$00#$D5#$60#$EC#$38#$00#$00#$00#$00#$14#$00#$00#$00#$02#$01 +
    #$41#$31#$B0#$F2#$8C#$42#$CB#$61#$11#$C3#$3F#$75#$1A#$43#$03#$00 +
    #$00#$00#$00#$00#$00#$00#$32#$63#$EC#$38#$00#$00#$00#$00#$14#$00 +
    #$00#$00#$02#$01#$41#$31#$6D#$E7#$9D#$41#$F6#$C8#$02#$C3#$17#$D9 +
    #$0F#$C2#$03#$00#$00#$00#$05#$01#$00#$00#$00#$71#$41#$AA#$AB#$00 +
    #$00#$00#$00#$14#$00#$00#$00#$03#$02#$41#$31#$89#$41#$F8#$41#$D5 +
    #$98#$1C#$43#$C5#$30#$98#$C3#$02#$00#$00#$00#$00#$00#$00#$00#$96 +
    #$99#$AA#$AB#$00#$00#$00#$00#$14#$00#$00#$00#$03#$02#$41#$31#$4C +
    #$B7#$A2#$C2#$71#$3D#$8F#$C1#$56#$5E#$F0#$43#$03#$00#$00#$00#$00 +
    #$00#$00#$00#$E0#$13#$AB#$AB#$00#$00#$00#$00#$14#$00#$00#$00#$03 +
    #$02#$41#$31#$46#$B6#$99#$C1#$08#$6C#$90#$42#$A2#$05#$14#$C3#$03 +
    #$00#$00#$00#$00#$00#$00#$00#$A7#$93#$AB#$AB#$00#$00#$00#$00#$14 +
    #$00#$00#$00#$03#$02#$41#$31#$98#$AE#$88#$C2#$8F#$C2#$1B#$C1#$C7 +
    #$5B#$C4#$43#$03#$00#$00#$00#$00#$00#$00#$00#$5F#$BD#$AB#$AB#$00 +
    #$00#$00#$00#$14#$00#$00#$00#$03#$02#$41#$31#$C5#$60#$D0#$C2#$9A +
    #$19#$0B#$42#$0A#$97#$CA#$42#$03#$00#$00#$00#$00#$00#$00#$00#$00 +
    #$00#$00#$00#$00#$00#$00#$00#$00#$00#$00
  );

  result.Free;
end;

procedure TGame.HandlePlayerChangeGameSettings(const client: TGameClient; const clientPacket: TClientPacket);
var
  nbOfActions: UInt8;
  action: UInt8;
  i: UInt8;
  tmpStr: AnsiString;
  tmpUInt8: UInt8;
  tmpUInt16: UInt16;
  tmpUInt32: UInt32;
  gameInfo: TPlayerCreateGameInfo;
  currentPlayersCount: UInt16;
begin
  Console.Log('TGame.HandlePlayerChangeGameSettings', C_BLUE);

  clientPacket.Skip(2);

  if not clientPacket.ReadUInt8(nbOfActions) then
  begin
    Console.Log('Failed to read nbOfActions', C_RED);
    Exit;
  end;

  gameInfo := m_gameInfo;
  currentPlayersCount := self.PlayerCount;

  for i := 1 to nbOfActions do begin

    if not clientPacket.ReadUInt8(action) then begin
      console.log('Failed to read action', C_RED);
      break;
    end;

    case action of
      0: begin
        clientPacket.ReadPStr(tmpStr);
        // TODO: Should Check the size maybe
        m_name := tmpStr;
      end;
      1: begin
        clientPacket.ReadPStr(tmpStr);
        // TODO: Should Check the size maybe
        m_password := tmpStr;
      end;
      3: begin
        clientPacket.ReadUInt8(tmpUInt8);
        gameInfo.map := tmpUInt8;
      end;
      4: begin
        clientPacket.ReadUInt8(tmpUInt8);
        gameInfo.holeCount := tmpUInt8;
      end;
      5: begin
        clientPacket.ReadUInt8(tmpUInt8);
        gameInfo.Mode := TGAME_MODE(tmpUInt8);
      end;
      6: begin
        clientPacket.ReadUInt8(tmpUInt8);
        gameInfo.turnTime := tmpUInt8 * 1000;
      end;
      7: begin
        clientPacket.ReadUInt8(tmpUInt8);
        if tmpUInt8 > currentPlayersCount then
        begin
          gameInfo.maxPlayers := tmpUInt8;
        end;
      end;
      14: begin
        clientPacket.ReadUInt32(tmpUInt32);
      end
      else begin
        Console.Log(Format('Unknow action %d', [action]));
      end;
    end;
  end;

  self.TriggerGameUpdated;

end;

procedure TGame.TriggerGameUpdated;
begin

  // game update
  self.Send(
    #$4A#$00 +
    #$FF#$FF +
    self.GameResume
  );

  // Send lobby update
  self.m_onUpdateGame.Trigger(self);

end;

procedure TGame.RandomizeWeather;
var
  holeInfo: TGameHoleInfo;
  flagged: Boolean;
begin
  flagged := false;
  for holeInfo in m_game_holes do
  begin
    if flagged then
    begin
      holeInfo.weather := 2;
      break;
    end;
    if random(100) <= m_rain_drop_ratio then
    begin
      holeInfo.weather := 1;
      flagged := true;
    end else
    begin
      holeInfo.weather := 0;
    end;
  end;
end;

procedure TGame.RandomizeWind;
var
  holeInfo: TGameHoleInfo;
  flagged: Boolean;
begin
  flagged := false;
  for holeInfo in m_game_holes do
  begin
    holeInfo.Wind.windpower := UInt8(random(9));
  end;
end;

procedure TGame.HandlePlayer1stShotReady;
var
  player: TGameClient;
  numberOfPlayerRdy: UInt8;
begin
  Console.Log('TGame.HandlePlayerChangeGameSettings', C_BLUE);

  numberOfPlayerRdy :=0;

  for player in m_players do
  begin
    if player.Data.LoadComplete then
    begin
      Inc(numberOfPlayerRdy)
    end;
  end;

  if not (numberOfPlayerRdy = m_players.Count) then
  begin
    Exit;
  end;

  self.Send(WriteAction(SGPID_PLAYER_1ST_SHOT_READY));
end;

procedure TGame.HandlePlayerActionShot(const client: TGameClient; const clientPacket: TClientPacket);
type
  TInfo2 = packed record
    un1: array [0..$3D] of AnsiChar;
  end;
  TInfo1 = packed record
    un1: array [0..$8] of AnsiChar;
    un2: TInfo2;
  end;
var
  shotType: UInt16;
  shotInfo: TInfo1;
  res: TClientPacket;
begin
  Console.Log('TGame.HandlePlayerActionShot', C_BLUE);
  clientPacket.ReadUInt16(shotType);

  res := TClientPacket.Create;
  res.WriteStr(WriteAction(SGPID_PLAYER_ACTION_SHOT));
  res.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);

  if shotType = 1 then
  begin
    clientPacket.Read(shotInfo, SizeOf(TInfo1));
    res.Write(shotInfo.un2, SizeOf(TInfo2));
  end else
  begin
    clientPacket.Read(shotInfo.un2, SizeOf(TInfo2));
    res.Write(shotInfo.un2, SizeOf(TInfo2));
  end;

  self.Send(res);

  res.Free;
end;

procedure TGame.HandlePlayerActionRotate(const client: TGameClient; const clientPacket: TClientPacket);
var
  angle: Double;
  res: TClientPacket;
begin
  Console.Log('TGame.HandlePlayerActionRoate', C_BLUE);
  Console.Log(Format('Angle : %f', [angle]));

  clientPacket.ReadDouble(angle);
  res := TClientPacket.Create;

  res.WriteStr(WriteAction(SGPID_PLAYER_ACTION_ROTATE));
  res.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);
  res.WriteDouble(angle);

  self.Send(res);

  res.Free;
end;

procedure TGame.HandlePlayerActionHit(const client: TGameClient; const clientPacket: TClientPacket);
begin
  Console.Log('TGame.HandlePlayerActionHit', C_BLUE);

end;

procedure TGame.HandlePlayerActionChangeClub(const client: TGameClient; const clientPacket: TClientPacket);
var
  clubType: TCLUB_TYPE;
  res: TClientPacket;
begin
  Console.Log('TGame.HandlePlayerActionChangeClub', C_BLUE);
  if not clientPacket.Read(clubType, 1) then
  begin
    Exit;
  end;

  res := TClientPacket.Create;

  res.WriteStr(WriteAction(SGPID_PLAYER_ACTION_CHANGE_CLUB));
  res.WriteUInt32(client.Data.Data.playerInfo1.ConnectionId);
  res.Write(clubType, 1);

  self.Send(res);

  res.Free;
end;

procedure TGame.DecryptShot(data: PAnsiChar; size: UInt32);
var
  x: Integer;
begin
  for x := 0 to size-1 do
  begin
    data[x] := ansichar(byte(data[x]) xor byte(m_gameKey[x mod 16]));
  end;
end;

procedure TGame.HandlePlayerShotData(const client: TGameClient; const clientPacket: TClientPacket);
var
  data: TShotData;
  tmp: AnsiString;
begin
  console.Log('TGame.HandlePlayerShotData', C_BLUE);

  clientPacket.Read(data, SizeOf(TShotData));
  DecryptShot(@data, SizeOf(TShotData));

  setLength(tmp, SizeOf(TShotData));
  move(data, tmp[1], SizeOf(TShotData));
  Console.WriteDump(tmp);

end;

procedure TGame.HandlePlayerShotSync(const client: TGameClient; const clientPacket: TClientPacket);
var
  player: TGameClient;
  numberOfPlayerRdy: UInt8;
  res: TClientPacket;
begin
  Console.Log('TGame.HandlePlayerShotSync', C_BLUE);
  client.Data.ShotSync := true;
  numberOfPlayerRdy := 0;

  for player in m_players do
  begin
    if player.Data.LoadComplete then
    begin
      Inc(numberOfPlayerRdy)
    end;
  end;

  if not (numberOfPlayerRdy = m_players.Count) then
  begin
    Exit;
  end;

  // Should update Wind
  // 5B 00 06 00 4A 00 01

  res := TClientPacket.Create;

  res.WriteStr(WriteAction(SGPID_PLAYER_NEXT));

  // Supposed to choose the right next player o_O
  res.WriteInt32(client.Data.Data.playerInfo1.ConnectionId);

  self.Send(res);

  res.Free;
end;

end.
