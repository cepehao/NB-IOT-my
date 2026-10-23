function execution=localDevelopment()
%LOCALDEVELOPMENT Safe execution defaults, separate from scientific config.
execution=struct('profile','local-development','role','development', ...
    'maxUE',10,'maxCaseSeconds',300,'maxSuiteSeconds',900);
end
