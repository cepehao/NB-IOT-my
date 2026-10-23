% Open the application with a small, strong-link demo preset.
% Does not start a simulation. Press the Run button yourself.
meetingRoot=fileparts(mfilename('fullpath'));
cd(meetingRoot); setupProject();
meetingApp=openNBIoTApp();
meetingPreset={ ...
    'simulationMode','Static'; ...
    'numUE',1; 'durationTicks',5000; 'radiusM',20; ...
    'indoorFraction',0; 'shadowOutdoorDb',0; 'shadowIndoorDb',0; ...
    'cfoSigmaHz',0; 'syncLimitSeconds',0; ...
    'trafficKind','burst'; 'burstStartTick',0; 'burstDurationTicks',1};
for meetingIndex=1:size(meetingPreset,1)
    meetingControl=findall(meetingApp.Figure,'Tag',meetingPreset{meetingIndex,1});
    assert(isscalar(meetingControl),'Demo preset field was not found.');
    meetingControl.Value=meetingPreset{meetingIndex,2};
end
drawnow;
disp('Demo preset: Static, 1 device, 200 bytes, strong link, 5 model seconds.');
disp('The simulation has NOT started. Press Запуск in the application.');
disp('Expected after completion: 1 packet delivered, 1600 payload bits.');
disp('This is a favorable-link demonstration, not network-wide performance.');
