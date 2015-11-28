unit PlayerAction;

interface

uses PlayerPos;

type

  PPlayerAction = ^TPlayerAction;
  TPlayerAction = packed record
    lastAction: cardinal;
    pos: TPlayerPos;
    procedure clear;
    function toAnsiString: ansistring;
  end;

implementation

procedure TPlayerAction.clear;
begin
  FillChar(self.lastAction, SizeOf(TPlayerAction), 0);
end;

function TPlayerAction.toAnsiString: ansistring;
begin
  setLength(result, sizeof(TPlayerAction));
  move(lastAction, result[1], sizeof(TPlayerAction));
end;

end.
