classdef LiveRadioCountingSimulator < nbiot.NBIoTSimulator
    %LIVERADIOCOUNTINGSIMULATOR Count batch-result requests made by snapshots.
    properties (SetAccess=private)
        ResultCallCount = 0
    end
    properties (Access=private)
        LiveDiagnosticsOverride = []
    end

    methods
        function obj=LiveRadioCountingSimulator(varargin)
            obj@nbiot.NBIoTSimulator(varargin{:});
        end

        function result=result(obj)
            obj.ResultCallCount=obj.ResultCallCount+1;
            result=result@nbiot.NBIoTSimulator(obj);
        end

        function setLiveDiagnosticsOverride(obj,value)
            obj.LiveDiagnosticsOverride=value;
        end

        function live=liveRadioDiagnostics(obj)
            if isempty(obj.LiveDiagnosticsOverride)
                live=liveRadioDiagnostics@nbiot.NBIoTSimulator(obj);
            else
                live=obj.LiveDiagnosticsOverride;
            end
        end
    end
end
