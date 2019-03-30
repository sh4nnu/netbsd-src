atf_test_case indent_t
indent_t_head()
{
    atf_set "decsr" "This is a sample indent test"
    atf_set "require.progs" "indent"
}
indent_t_body()
{
    cd indent_tests
    for file in ./*.0
        do
            indent -P$file.pro $file
        done
    for file in ./*.0
        do
            atf-check -s exit:0 -e ignore -o match:cat file.stdout cat file
        done
}       
atf_init_test_cases()
{
    atf_add_test_case indent_t
}