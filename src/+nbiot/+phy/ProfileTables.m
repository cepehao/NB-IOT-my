classdef ProfileTables
    % Release-13 tables used by static-v1; reserved entries fail explicitly.
    methods (Static)
        function p = profile(kind)
            % Value structs use copy-on-write: callers cannot mutate the cache.
            % Only immutable profile constants are cached, never grants or RX state.
            persistent msg3 data ack downlink npdcch
            if isempty(msg3)
                base=struct('format','Data','spacingHz',15000,'numSubcarriers',3,...
                    'modulation','QPSK','nru',1,'nulSlots',8,'repetitions',2,...
                    'tbs',88,'mcs',6,'iru',0,'durationTicks',8);
                msg3=base; msg3.rarIndex=2;
                data=base; data.nru=4; data.tbs=256; data.mcs=4;
                data.iru=3; data.durationTicks=32;
                ack=base; ack.format='Control'; ack.numSubcarriers=1;
                ack.modulation='BPSK'; ack.nulSlots=4; ack.tbs=1;
                ack.mcs=0; ack.durationTicks=4;
                downlink=base; downlink.format='NPDSCH'; downlink.numSubcarriers=12;
                downlink.nsf=1; downlink.durationTicks=2;
                npdcch=base; npdcch.format='NPDCCH'; npdcch.numSubcarriers=12;
                npdcch.durationTicks=2; npdcch.rmax=4; npdcch.g=8;
                npdcch.offset=0; npdcch.ncce=[0 1];
            end
            switch lower(char(kind))
                case 'msg3'
                    p=msg3;
                case {'data','npusch'}
                    p=data;
                case {'ack','control'}
                    p=ack;
                case {'downlink','rar','msg4','receipt','npdsch'}
                    p=downlink;
                case {'npdcch','n0','n1'}
                    p=npdcch;
                otherwise
                    error('nbiot:phy:Profile','Unknown profile %s.',kind);
            end
        end
        function p=msg3Profile(index)
            validateattributes(index,{'numeric'},{'scalar','integer','>=',0,'<=',2});
            p=nbiot.phy.ProfileTables.profile('msg3');
            nr=[4 3 1]; p.nru=nr(index+1); p.rarIndex=index;
            p.iru=find([1 2 3 4 5 6 8 10]==p.nru)-1;
            p.durationTicks=p.nru*p.nulSlots*p.repetitions/2;
        end
        function t=ulTbs(mcs,iru,nsc)
            validateattributes(mcs,{'numeric'},{'scalar','integer','>=',0,'<=',12});
            validateattributes(iru,{'numeric'},{'scalar','integer','>=',0,'<=',7});
            assert(ismember(nsc,[1 3 6 12]),'nbiot:phy:Allocation','Invalid tone count.');
            if nsc==1
                assert(mcs<=10,'nbiot:phy:Reserved','Reserved single-tone MCS.');
                map=[0 2 1 3 4 5 6 7 8 9 10]; mcs=map(mcs+1);
            end
            a=[16 32 56 88 120 152 208 256;24 56 88 144 176 208 256 344;...
                32 72 144 176 208 256 328 424;40 104 176 208 256 328 440 568;...
                56 120 208 256 328 408 552 680;72 144 224 328 424 504 680 872;...
                88 176 256 392 504 600 808 1000;104 224 328 472 584 712 1000 NaN;...
                120 256 392 536 680 808 NaN NaN;136 296 456 616 776 936 NaN NaN;...
                144 328 504 680 872 1000 NaN NaN;176 376 584 776 1000 NaN NaN NaN;...
                208 440 680 1000 NaN NaN NaN NaN];
            t=a(mcs+1,iru+1); assert(isfinite(t),'nbiot:phy:Reserved','Reserved TBS combination.');
        end
        function t=dlTbs(mcs,isf)
            validateattributes(mcs,{'numeric'},{'scalar','integer','>=',0,'<=',12});
            validateattributes(isf,{'numeric'},{'scalar','integer','>=',0,'<=',7});
            a=[16 32 56 88 120 152 208 256;24 56 88 144 176 208 256 344;...
                32 72 144 176 208 256 328 424;40 104 176 208 256 328 440 568;...
                56 120 208 256 328 408 552 680;72 144 224 328 424 504 680 NaN;...
                88 176 256 392 504 600 NaN NaN;104 224 328 472 584 680 NaN NaN;...
                120 256 392 536 680 NaN NaN NaN;136 296 456 616 NaN NaN NaN NaN;...
                144 328 504 680 NaN NaN NaN NaN;176 376 584 NaN NaN NaN NaN NaN;...
                208 440 680 NaN NaN NaN NaN NaN];
            t=a(mcs+1,isf+1); assert(isfinite(t),'nbiot:phy:Reserved','Reserved DL TBS combination.');
        end
        function v=n0Delay(i), v=nbiot.phy.ProfileTables.lookup([8 16 32 64],i); end
        function v=rarDelay(i), v=nbiot.phy.ProfileTables.lookup([12 16 32 64],i); end
        function v=n1Delay(i,rmax)
            if rmax<128, a=[0 4 8 12 16 32 64 128]; else, a=[0 16 32 64 128 256 512 1024]; end
            v=nbiot.phy.ProfileTables.lookup(a,i);
        end
        function v=resourceUnits(i), v=nbiot.phy.ProfileTables.lookup([1 2 3 4 5 6 8 10],i); end
        function v=dlSubframes(i), v=nbiot.phy.ProfileTables.resourceUnits(i); end
        function v=ulRepetitions(i), v=nbiot.phy.ProfileTables.lookup(2.^(0:7),i); end
        function v=dlRepetitions(i), v=nbiot.phy.ProfileTables.lookup([1 2 4 8 16 32 64 128 192 256 384 512 768 1024 1536 2048],i); end
        function sc=decodeUlAssignment(i)
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<=',18});
            if i<12, sc=i; elseif i<16, sc=3*(i-12)+(0:2); elseif i<18, sc=6*(i-16)+(0:5); else, sc=0:11; end
        end
        function i=encodeUlAssignment(sc)
            for j=0:18
                if isequal(sc(:)',nbiot.phy.ProfileTables.decodeUlAssignment(j)), i=j; return; end
            end
            error('nbiot:phy:Allocation','Unsupported contiguous allocation.');
        end
        function [tone,k0]=ackResource(i)
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<=',15});
            tone=mod(i,4); a=[13 15 17 18]; k0=a(floor(i/4)+1);
        end
        function v=nprachDurationTicks(), v=6; end
        function v=lookup(a,i)
            validateattributes(i,{'numeric'},{'scalar','integer','>=',0,'<',numel(a)}); v=a(i+1);
        end
    end
end
