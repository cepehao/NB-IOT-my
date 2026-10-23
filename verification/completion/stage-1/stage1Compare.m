evidenceFolder=fileparts(mfilename('fullpath'));
baseline=load(fullfile(evidenceFolder,'baseline-physical.mat'));
candidate=load(fullfile(evidenceFolder,'candidate-physical.mat'));
a=baseline.result; b=candidate.result;
names={'config','scenario','randomness','status','actualTick','stopReason','error', ...
    'packetLog','raLog','observedLog','truthLog','phyLog','ueSummary','resourceUsage','dataset','environment'};
for k=1:numel(names)
    assert(isequaln(a.(names{k}),b.(names{k})),['Radio/scientific field changed: ' names{k}]);
    fprintf('EXACT_FIELD_PASS %s\n',names{k});
end
assert(isequaln(baseline.rngBefore,candidate.rngBefore));
assert(isequaln(baseline.rngAfter,candidate.rngAfter));
oldNames=fieldnames(a.kpiSummary);
for k=1:numel(oldNames), assert(isequaln(a.kpiSummary.(oldNames{k}),b.kpiSummary.(oldNames{k}))); end
fprintf('OLD_KPI_FIELDS_PASS count=%d\n',numel(oldNames));
projected=b;
projected=rmfield(projected,setdiff(fieldnames(projected),fieldnames(a)));
projected.kpiSummary=rmfield(projected.kpiSummary,setdiff(fieldnames(projected.kpiSummary),oldNames));
projected.kpiTimeSeries=projected.kpiTimeSeries(:,a.kpiTimeSeries.Properties.VariableNames);
reference=a; reference.profiling.elapsedSeconds=[]; projected.profiling.elapsedSeconds=[];
assert(isequaln(reference,projected));
fprintf('EXACT_LEGACY_MAT_PROJECTION_PASS excluded=new-fields,new-KPI-columns,wall-clock-elapsedSeconds\n');
stem='static-v1_n1_r0000';
for suffix={'_ue.csv','_kpi.csv','_observations.csv','_targets.csv','_resources.csv','_split.csv'}
    name=[stem suffix{1}];
    x=readtable(fullfile(evidenceFolder,'baseline-exports',name),'VariableNamingRule','preserve');
    y=readtable(fullfile(evidenceFolder,'candidate-exports',name),'VariableNamingRule','preserve');
    count=width(x); assert(isequal(x.Properties.VariableNames,y.Properties.VariableNames(1:count)));
    assert(isequaln(x,y(:,1:count))); fprintf('CSV_PREFIX_PASS %s columns=%d rows=%d\n',name,count,height(x));
end
fprintf('STAGE1_PHYSICAL_EQUIVALENCE_PASS\n');
