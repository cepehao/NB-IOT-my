projectRoot=fileparts(fileparts(fileparts(mfilename('fullpath'))));
projectRoot=char(java.io.File(projectRoot).getCanonicalPath());
cd(projectRoot); addpath(projectRoot); setupProject();
addpath(fullfile(projectRoot,'verification','completion','stage-2'));
cfg=nbiot.experiments.loadCalibration(nbiot.config.defaultConfig(), ...
    fullfile(projectRoot,'results','nprach-calibration.mat'));
cfg.simulation.seed=43;
design=validateCollisionCapture(struct('designOnly',true));
registryFile=fullfile(projectRoot,'experiments','realizationRegistry.json');
candidates=nbiot.experiments.availableRealizationIds(registryFile, ...
    'stage-2-collision-diagnostics',1000:3999);
fprintf('STAGE2_ID_PROBE candidates=%d requestedPerCondition=10 seed=%d\n', ...
    numel(candidates),cfg.simulation.seed);
for ci=1:numel(design.conditions)
    condition=design.conditions(ci); matches=[];
    for id=candidates
        sources=nbiot.randomness.RandomSources(cfg.simulation.seed,id);
        indices=zeros(1,condition.numUE);
        for ue=1:condition.numUE
            stream=sources.stream('access',0,ue,1);
            rand(stream); indices(ue)=floor(rand(stream)*12);
        end
        if (condition.samePreamble&&numel(unique(indices))==1)|| ...
                (~condition.samePreamble&&numel(unique(indices))==condition.numUE)
            matches(end+1)=id; %#ok<AGROW>
            if numel(matches)==10, break; end
        end
    end
    fprintf('STAGE2_ID_PATTERN condition=%02d name=%s ue=%d same=%d matching=%d needed=10\n', ...
        condition.id,condition.name,condition.numUE,condition.samePreamble,numel(matches));
end
