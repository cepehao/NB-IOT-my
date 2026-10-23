classdef TestCheckpointFileHash < matlab.unittest.TestCase
    methods (Test)
        function knownShaAndByteChange(t)
            p=[tempname '.bin']; t.addTeardown(@()delete(p));
            fid=fopen(p,'wb'); fwrite(fid,uint8('abc'),'uint8'); fclose(fid);
            t.verifyEqual(nbiot.ml.fileSha256(p), ...
                'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
            fid=fopen(p,'r+b'); fwrite(fid,uint8('z'),'uint8'); fclose(fid);
            t.verifyNotEqual(nbiot.ml.fileSha256(p), ...
                'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
        end

        function emptyFileHasKnownSha(t)
            p=[tempname '.bin']; t.addTeardown(@()delete(p));
            fid=fopen(p,'wb'); fclose(fid);
            t.verifyEqual(nbiot.ml.fileSha256(p), ...
                'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
        end

        function multipleBlocksMatchIndependentDotNetSha(t)
            p=[tempname '.bin']; t.addTeardown(@()delete(p));
            fid=fopen(p,'wb');
            for k=1:8192, fwrite(fid,uint8(0:255),'uint8'); end
            fwrite(fid,uint8(0:16),'uint8'); fclose(fid);
            t.verifyEqual(dir(p).bytes,2*1024*1024+17);
            stream=System.IO.FileStream(p,System.IO.FileMode.Open,System.IO.FileAccess.Read,System.IO.FileShare.Read);
            streamCleanup=onCleanup(@()stream.Dispose());
            sha=System.Security.Cryptography.SHA256.Create();
            shaCleanup=onCleanup(@()sha.Dispose()); %#ok<NASGU>
            bytes=uint8(sha.ComputeHash(stream));
            independent=lower(reshape(dec2hex(bytes,2).',1,[]));
            clear streamCleanup
            t.verifyEqual(nbiot.ml.fileSha256(p),independent);
        end
    end
end
