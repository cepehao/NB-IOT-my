%INSPECTRECEIVEREVIDENCE Print a compact view of saved receiver checks.
projectRoot=fileparts(fileparts(fileparts(fileparts(mfilename('fullpath')))));
addpath(genpath(fullfile(projectRoot,'src')));
matFile=fullfile(projectRoot,'verification','completion','stage-2', ...
    'physical-20261007-122845-858','receiver-checks.mat');
info=whos('-file',matFile);
fprintf('RECEIVER_EVIDENCE file=%s variables=%d\n',matFile,numel(info));
for k=1:numel(info)
    fprintf('VARIABLE name=%s class=%s size=%s bytes=%d\n', ...
        info(k).name,info(k).class,mat2str(info(k).size),info(k).bytes);
end
data=load(matFile);
names=fieldnames(data);
for k=1:numel(names)
    value=data.(names{k});
    fprintf('TOP name=%s class=%s size=%s\n', ...
        names{k},class(value),mat2str(size(value)));
    if istable(value)
        fprintf('TABLE_COLUMNS name=%s columns=%s\n',names{k}, ...
            strjoin(value.Properties.VariableNames,','));
    elseif isstruct(value) && ~isempty(value)
        fprintf('STRUCT_FIELDS name=%s fields=%s\n',names{k}, ...
            strjoin(fieldnames(value),','));
    end
end
checks=data.checks;
saved=data.saved;
for kind=["cfoMinus200","cfoPlus200"]
    index=find(string(checks.condition)==kind,1);
    entry=saved{index};
    fprintf('CFO_ENTRY condition=%s row=%d class=%s size=%s\n', ...
        kind,index,class(entry),mat2str(size(entry)));
    if isstruct(entry)
        fields=fieldnames(entry);
        fprintf('CFO_ENTRY_FIELDS %s\n',strjoin(fields,','));
        for j=1:numel(fields)
            value=entry.(fields{j});
            fprintf('CFO_FIELD name=%s class=%s size=%s\n', ...
                fields{j},class(value),mat2str(size(value)));
            if isstruct(value) && isfield(value,'nInit')
                for q=1:numel(value)
                    fprintf('DETECTED nInit=%d metric=%.9g delay=%.9g cfo=%.9g\n', ...
                        value(q).nInit,value(q).metric,value(q).delaySeconds,value(q).cfoHz);
                end
            end
        end
    end
end
calibration=load(fullfile(projectRoot,'results','nprach-calibration.mat'),'report');
fprintf('CALIBRATION threshold=%.9g accepted=%d\n', ...
    calibration.report.threshold,calibration.report.accepted);
kinds=reshape(unique(string(checks.condition),'stable'),1,[]);
for kind=kinds
    rows=find(string(checks.condition)==kind);
    minOwn=Inf; maxFalse=0; detectedCounts=zeros(numel(rows),1);
    for j=1:numel(rows)
        row=rows(j); metric=saved{row}.metrics(:); target=checks.index(row)+1;
        if checks.present(row), minOwn=min(minOwn,metric(target)); end
        metric(target)=0; maxFalse=max(maxFalse,max(metric));
        detectedCounts(j)=numel(saved{row}.detected);
    end
    fprintf('METRIC_SUMMARY condition=%s minOwn=%.9g maxFalse=%.9g falseAlarmCases=%d/%d detectedRange=%d:%d\n', ...
        kind,minOwn,maxFalse,sum(checks.falseAlarm(rows)),numel(rows), ...
        min(detectedCounts),max(detectedCounts));
end