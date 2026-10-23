classdef TestProfileCache < matlab.unittest.TestCase
    methods (Test)
        function aliasesRetainEveryFieldAndType(t)
            names={'msg3','data','npusch','ack','control','downlink','rar', ...
                'msg4','receipt','npdsch','npdcch','n0','n1'};
            for k=1:numel(names)
                expected=legacyProfile(names{k});
                actual=nbiot.phy.ProfileTables.profile(names{k});
                t.verifyEqual(actual,expected);
                t.verifyEqual(fieldnames(actual),fieldnames(expected));
                t.verifyEqual(nbiot.phy.ProfileTables.profile(upper(string(names{k}))),expected);
            end
        end
        function returnedValueCannotChangeCachedProfile(t)
            names={'msg3','data','ack','downlink','npdcch'};
            for k=1:numel(names)
                p=nbiot.phy.ProfileTables.profile(names{k});
                p.tbs=-1; p.format='mutated'; p.extra=9; %#ok<NASGU>
                t.verifyEqual(nbiot.phy.ProfileTables.profile(names{k}),legacyProfile(names{k}));
            end
            for index=0:2
                p=nbiot.phy.ProfileTables.msg3Profile(index);
                expected=legacyProfile('msg3'); nr=[4 3 1];
                expected.nru=nr(index+1); expected.rarIndex=index;
                expected.iru=find([1 2 3 4 5 6 8 10]==expected.nru)-1;
                expected.durationTicks=expected.nru*expected.nulSlots*expected.repetitions/2;
                t.verifyEqual(p,expected);
            end
            t.verifyEqual(nbiot.phy.ProfileTables.profile('msg3'),legacyProfile('msg3'));
        end
        function unknownProfilesKeepErrorContract(t)
            t.verifyError(@() nbiot.phy.ProfileTables.profile('unknown'),'nbiot:phy:Profile');
            t.verifyError(@() nbiot.phy.ProfileTables.profile(''),'nbiot:phy:Profile');
        end
    end
end

function p=legacyProfile(kind)
p=struct('format','Data','spacingHz',15000,'numSubcarriers',3,...
    'modulation','QPSK','nru',1,'nulSlots',8,'repetitions',2,...
    'tbs',88,'mcs',6,'iru',0,'durationTicks',8);
switch lower(char(kind))
    case 'msg3', p.rarIndex=2;
    case {'data','npusch'}
        p.nru=4; p.tbs=256; p.mcs=4; p.iru=3; p.durationTicks=32;
    case {'ack','control'}
        p.format='Control'; p.numSubcarriers=1; p.modulation='BPSK';
        p.nulSlots=4; p.tbs=1; p.mcs=0; p.durationTicks=4;
    case {'downlink','rar','msg4','receipt','npdsch'}
        p.format='NPDSCH'; p.numSubcarriers=12; p.nsf=1; p.durationTicks=2;
    case {'npdcch','n0','n1'}
        p.format='NPDCCH'; p.numSubcarriers=12; p.durationTicks=2;
        p.rmax=4; p.g=8; p.offset=0; p.ncce=[0 1];
    otherwise, error('nbiot:phy:Profile','Unknown profile %s.',kind);
end
end
