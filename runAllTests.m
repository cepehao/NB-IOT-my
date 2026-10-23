function results = runAllTests(tag)
%RUNALLTESTS Прогон набора тестов проекта (matlab.unittest).
%   results = runAllTests()      — все тесты, кроме помеченных 'Slow'.
%   results = runAllTests('all') — все тесты, включая 'Slow'.
%   results = runAllTests(tag)   — только тесты с тегом, например 'TZ31'.
%   См. скилл nbiot-project-rules §6.

arguments
    tag (1,1) string = ""
end

import matlab.unittest.TestSuite
import matlab.unittest.selectors.HasTag

startupProject();
root = fileparts(mfilename('fullpath'));
suite = TestSuite.fromFolder(fullfile(root, 'tests'), 'IncludingSubfolders', true);

if tag == ""
    suite = suite.selectIf(~HasTag('Slow'));
elseif tag ~= "all"
    suite = suite.selectIf(HasTag(tag));
end

results = run(suite);
disp(table(results));
end
