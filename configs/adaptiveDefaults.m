function policy=adaptiveDefaults()
%ADAPTIVEDEFAULTS Provisional development-only load thresholds.
policy=struct();
policy.windowTicks=500;
policy.staticAccessProbability=1;
policy.staticRaShare=0.1;
% Initial monotone levels for development tests; tune only on real validation IDs.
policy.accessLoadThresholds=[1 3 6 10];
policy.accessProbabilityLevels=[1 0.75 0.5 0.25 0.1];
policy.raLoadThresholds=[1 5];
policy.raShareLevels=[0.1 0.2 0.3];
policy.maximumLoad=100000;
policy.status='development-provisional';
end
