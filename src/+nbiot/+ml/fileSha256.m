function digest=fileSha256(file)
%FILESHA256 Return a lowercase SHA-256 digest for a saved model artifact.
%   SHA-256 файла (строчные hex) — для привязки модели/калибровки к результату.
if ~isfile(file), error('nbiot:ml:PackageFile','Model artifact does not exist.'); end
md=java.security.MessageDigest.getInstance('SHA-256');
fid=fopen(file,'rb');
if fid<0, error('nbiot:ml:PackageFile','Cannot read model artifact.'); end
cleanup=onCleanup(@() fclose(fid));
while ~feof(fid)
    bytes=fread(fid,1024*1024,'*uint8');
    if ~isempty(bytes), md.update(typecast(bytes,'int8')); end
end
digest=lower(reshape(dec2hex(typecast(md.digest(),'uint8'),2).',1,[]));
end
