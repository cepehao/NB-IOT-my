classdef NaNRegressionPredictor
    methods
        function prediction=predict(~,features)
            prediction=nan(size(features,1),1);
        end
    end
end
