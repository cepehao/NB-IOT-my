function [truth,observed,receptions,options]=makeRadioDiagnosticsScaleFixture(pairCount)
%MAKERADIODIAGNOSTICSSCALEFIXTURE Exact synthetic pairs; no PHY or RNG.
validateattributes(pairCount,{'numeric'},{'scalar','integer','finite','positive'});
remaining=double(pairCount); sizes=zeros(1,0);
while remaining>0
    n=floor((1+sqrt(1+8*remaining))/2);
    sizes(end+1)=n; %#ok<AGROW>
    remaining=remaining-n*(n-1)/2;
end
count=sum(sizes); occasions=numel(sizes);
empty=struct('tick',1,'kind','','fields',struct());
truth=repmat(empty,1,2*count);
observed=repmat(empty,1,occasions);
receptions=repmat(empty,1,count+pairCount);
id=0; pairAt=count;
for occasionId=1:occasions
    n=sizes(occasionId); first=id+1;
    candidate=struct('nInit',0,'delaySeconds',0,'cfoHz',0);
    observed(occasionId)=ev('nprach_detection',struct('occasionId',occasionId,'candidates',candidate));
    for i=1:n
        id=id+1; ueId=1+mod(id-1,10);
        truth(id)=ev('msg1',struct('attemptId',id,'ueId',ueId,'occasionId',occasionId,'nInit',0));
        truth(count+id)=ev('ra_success',struct('attemptId',id));
        receptions(id)=ev('nprach_component',struct('occasionId',occasionId,'attemptId',id, ...
            'ueId',ueId,'nInit',0,'startSample',0,'endSampleExclusive',10, ...
            'signalPowerW',i,'interferencePowerW',0,'noisePowerW',1, ...
            'configuredDelaySeconds',0,'configuredCfoHz',0));
    end
    for i=1:n-1
        for j=i+1:n
            pairAt=pairAt+1;
            receptions(pairAt)=ev('nprach_overlap',struct('occasionId',occasionId, ...
                'attemptIdA',first+i-1,'attemptIdB',first+j-1, ...
                'startSample',0,'endSampleExclusive',10,'signalPowerAW',i,'signalPowerBW',j));
        end
    end
end
options=struct('actualTick',2,'nInitValues',0);
end

function e=ev(kind,fields)
e=struct('tick',1,'kind',kind,'fields',fields);
end
