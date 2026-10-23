function saveVariant2BudgetLedger(path,ledger)
%SAVEVARIANT2BUDGETLEDGER Atomically save shared Stage 2/Stage 3 compute progress.
if ~(ischar(path)||(isstring(path)&&isscalar(path)))||~isstruct(ledger)||~isscalar(ledger)
    error('nbiot:experiments:Variant2BudgetLedger','Invalid ledger path or value.');
end
path=char(path); folder=fileparts(path);
if ~isfolder(folder), [ok,message]=mkdir(folder); if ~ok, error('nbiot:experiments:Variant2BudgetLedger','%s',message); end, end
ledger.updatedAtUtc=char(datetime('now','TimeZone','UTC','Format','yyyy-MM-dd HH:mm:ss.SSS'));
temporary=[path '.' char(java.util.UUID.randomUUID()) '.tmp'];
cleanup=onCleanup(@() deleteTemporary(temporary)); %#ok<NASGU>
fid=fopen(temporary,'w','n','UTF-8');
if fid<0, error('nbiot:experiments:Variant2BudgetLedger','Cannot create temporary budget ledger.'); end
closeFile=onCleanup(@() fclose(fid)); %#ok<NASGU>
bytes=unicode2native(jsonencode(ledger,'PrettyPrint',true),'UTF-8');
if fwrite(fid,bytes,'uint8')~=numel(bytes)
    error('nbiot:experiments:Variant2BudgetLedger','Could not write complete budget ledger.');
end
clear closeFile
[ok,message]=movefile(temporary,path,'f');
if ~ok, error('nbiot:experiments:Variant2BudgetLedger','Cannot publish budget ledger: %s',message); end
end

function deleteTemporary(path)
if isfile(path), delete(path); end
end
