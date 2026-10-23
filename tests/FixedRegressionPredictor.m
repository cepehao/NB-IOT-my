classdef FixedRegressionPredictor
    properties
        Value
    end
    methods
        function obj=FixedRegressionPredictor(value)
            obj.Value=value;
        end
        function prediction=predict(obj,features)
            prediction=repmat(obj.Value,size(features,1),1);
        end
    end
end
