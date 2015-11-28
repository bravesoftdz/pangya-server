unit utils;

interface

uses
  SysUtils;

type
  TGeneric = class
    class function Iff<T>(const expression: Boolean; trueValue: T; falseValue: T): T; inline;
  end;

  TEvent<T> = procedure(enventObject: T) of object;
  TEvent2<T1, T2> = procedure(enventObject1: T1; eventObject2: T2) of object;

function GetDataFromfile(filePath: string): AnsiString;
procedure WriteDataToFile(filePath: string; data: AnsiString);

implementation

function GetDataFromfile(filePath: string): AnsiString;
var
  x: THandle;
  size: Integer;
  data: AnsiString;
begin
  x := fileopen(filepath, $40);
  size := fileseek(x, 0, 2);
  fileseek(x, 0, 0);
  setlength(data, size);
  fileread(x, data[1], size);
  fileclose(x);
  Exit(data);
end;

procedure WriteDataToFile(filePath: string; data: AnsiString);
var
  x: THandle;
  size: Integer;
begin
  x := FileCreate(filepath);
  size := Length(data);
  FileWrite(x, data[1], size);
  fileclose(x);
end;

class function TGeneric.Iff<T>(const expression: Boolean; trueValue: T; falseValue: T): T;
begin
  if (expression) then
  begin
    Exit(trueValue);
  end else
  begin
    Exit(falseValue);
  end;
end;

end.
