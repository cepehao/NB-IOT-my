function data=smallLoadTrainingFixture()
%SMALLLOADTRAININGFIXTURE Shared synthetic development-only load dataset.
schema=nbiot.dataset.featureSchema();
schema.keyNames=schema.observationNames(1:4);
schema.inputNames=schema.observationNames(5:end);
schema.targetName='meanRaUe';
ids=[11 12 13 21 31];
groups=["train" "train" "train" "validation" "test"];
rowsPerId=6; rowCount=numel(ids)*rowsPerId;
keys=zeros(rowCount,4); featureValues=zeros(rowCount,numel(schema.inputNames));
targetValues=zeros(rowCount,5); rowGroups=strings(rowCount,1); caseKeys=strings(rowCount,1);
cursor=0;
for idIndex=1:numel(ids)
    for window=1:rowsPerId
        cursor=cursor+1;
        id=ids(idIndex);
        keys(cursor,:)=[id window (window-1)*500 window*500];
        rowGroups(cursor)=groups(idIndex);
        caseKeys(cursor)=sprintf('fixture-%d',id);
        for featureIndex=1:numel(schema.inputNames)
            featureValues(cursor,featureIndex)= ...
                sin(cursor*(featureIndex+1)*.17)+cos(id*(featureIndex+2)*.013)+featureIndex*.1;
        end
        if idIndex>=4
            featureValues(cursor,1)=featureValues(cursor,1)+20;
        end
        targetValues(cursor,:)=[1+0.2*window+0.01*id 0.3 0.2 1 1];
    end
end
featureValues(1,2)=NaN;
features=array2table(featureValues,'VariableNames',schema.inputNames);
observations=[array2table(keys,'VariableNames',schema.keyNames) features];
targets=array2table([keys targetValues],'VariableNames',schema.targetNames);
rowInfo=table(caseKeys,keys(:,1),keys(:,2),keys(:,3),keys(:,4),rowGroups, ...
    'VariableNames',{'caseKey','realizationId','windowId','startTick','endTick','split'});
assignments=table(ids(:),groups(:),'VariableNames',{'externalRealizationId','split'});
roles=groups(:); roles(roles=="train")="training"; roles(roles=="test")="model-test";
assignments.experimentRole=roles;
manifest=struct('kind','development-fixture','version',1, ...
    'independentRealizations',numel(ids),'rows',rowCount,'allocationsVerified',false, ...
    'assignments',assignments);
manifest.inputs=struct([]);
manifest.experimentRolesExplicit=false;
data=struct('observations',observations,'targets',targets,'features',features, ...
    'rowInfo',rowInfo,'schema',schema,'manifest',manifest);
end
