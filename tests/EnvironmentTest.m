classdef EnvironmentTest < matlab.unittest.TestCase
    %ENVIRONMENTTEST Smoke-тест окружения (этап 0, ADR-001, ADR-002).
    %   Проверяет, что проект на пути, нужные тулбоксы и NB-IoT API доступны,
    %   а NPRACH loopback из LTE Toolbox детектирует преамбулу.

    properties (Constant)
        RequiredFunctions = {'lteNPRACH', 'lteNPRACHInfo', 'lteNPRACHDetect', ...
            'lteNULSCH', 'lteNULSCHDecode', 'lteNPUSCH', 'lteNPUSCHDecode', ...
            'lteNPDCCH', 'lteNPDCCHDecode', 'lteNPDSCH', 'lteNPDSCHDecode', ...
            'lteCRCEncode', 'lteCRCDecode', 'lteFadingChannel', 'lteFrequencyOffset', ...
            'parcluster'}
    end

    methods (Test)
        function srcPackageIsOnPath(testCase)
            root = fileparts(fileparts(mfilename('fullpath')));
            testCase.verifyTrue(isfolder(fullfile(root, 'src', '+nbiot')));
            testCase.verifyTrue(contains(path, fullfile(root, 'src')));
        end

        function requiredFunctionsExist(testCase)
            for k = 1:numel(testCase.RequiredFunctions)
                name = testCase.RequiredFunctions{k};
                testCase.verifyGreaterThan(exist(name), 0, ...
                    sprintf('Функция %s недоступна', name)); %#ok<EXIST>
            end
        end

        function nprachLoopbackDetectsPreamble(testCase)
            % ADR-002: формат 0, 48 поднесущих, NInit = 17, SNR 0 дБ, seed 42.
            ue = struct('NNCellID', 0, 'NBULSubcarrierSpacing', '15kHz');
            chs = struct('NPRACHFormat', '0', 'Periodicity', 80, ...
                'SubcarrierOffset', 0, 'NumSubcarriers', 48, 'NRep', 1, ...
                'StartTime', 8, 'NInit', 17);
            tx = lteNPRACH(ue, chs);

            stream = RandStream('Threefry', 'Seed', 42);
            snrDb = 0;
            noisePower = mean(abs(tx(tx ~= 0)).^2) / 10^(snrDb / 10);
            noise = sqrt(noisePower / 2) * ...
                (randn(stream, size(tx)) + 1i * randn(stream, size(tx)));

            detectedInit = lteNPRACHDetect(ue, chs, tx + noise);
            testCase.verifyEqual(detectedInit, 17);
        end
    end
end
